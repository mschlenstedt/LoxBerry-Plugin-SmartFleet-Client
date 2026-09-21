#!/usr/bin/perl
# SmartFleet Client
# Copyright (c) 2026 Michael Schlenstedt. Alle Rechte vorbehalten.
# Nutzung, Weitergabe und Veraenderung nur nach den Lizenzbedingungen,
# die diesem Programm beiliegen (LICENSE).

use strict;
use warnings;
use Getopt::Long;
use File::Spec;
use JSON::PP;

use FindBin qw($Bin);
use lib "$Bin/lib", "$Bin/../lib";

use FM::Paths;
use FM::Config;
use FM::State;
use FM::Loxlog;
use FM::Miniserver;
use FM::Events;
use FM::Spool;
use FM::Chart;
use FM::Projekt::Upload;

use constant LAUF_BUDGET    => 40;
use constant KATALOG_TEIL   => 400;
use constant KATALOG_RETRY  => 21600;
use constant KURZ_RETRY     => 300;

my ($dir, $verbose);
GetOptions('dir=s' => \$dir, 'verbose' => \$verbose)
    or die "Aufruf: fm_chart.pl --dir <konfigdir> [--verbose]\n";
die "fm_chart: --dir fehlt\n" if !$dir;

my $rt = FM::Paths::laufzeit($dir);
FM::Paths::uebernehmen($dir);

my $cfg = FM::Config::load($dir);
exit 0 if !$cfg->{site} || !$cfg->{server};
my $keyfile = FM::Config::keyfile($dir);

my $log;
sub say_v  { print "$_[0]\n" if $verbose; FM::Loxlog::inf($log, $_[0]) if $log; }
sub say_deb { print "$_[0]\n" if $verbose; FM::Loxlog::deb($log, $_[0]) if $log; }

my $lock = FM::State::lock($rt, 'chart');
if (!$lock) {
    say_v('Ein Chart-Lauf laeuft bereits - die Sperre ist belegt.');
    exit 0;
}

my $ok_lb = eval {
    require LoxBerry::System;
    no strict 'refs';
    die "get_miniservers fehlt\n" if !defined &{"LoxBerry::System::get_miniservers"};
    1;
};
if (!$ok_lb) {
    say_v('LoxBerry::System ist hier nicht verfuegbar - der Laeufer beendet sich.');
    exit 0;
}

my %miniservers = LoxBerry::System::get_miniservers();
for my $msno (keys %miniservers) {
    next if FM::Miniserver::ist_lokal($miniservers{$msno});
    delete $miniservers{$msno};
}
exit 0 if !%miniservers;

my $state = FM::State::load($rt);
$state->{chart} = {} if ref($state->{chart}) ne 'HASH';
my $now = time();
my $lauf_deadline = $now + LAUF_BUDGET;

my $reqfile     = File::Spec->catfile($rt, 'chart_katalog.req');
my $anforderung = -e $reqfile ? 1 : 0;
my $auswahl     = FM::Chart::auswahl_laden($dir);
my $gruppen     = FM::Chart::gruppen_der_auswahl($auswahl);
my $erfassen    = (@$auswahl && FM::Chart::due($state, $now)) ? 1 : 0;

sub katalog_hochladen {
    my ($msno, $base, $cred, $abruf, $ver, $cs) = @_;
    my ($ok, $body) = FM::Miniserver::get($base, $cred, '/data/LoxAPP3.json');
    my $la = $ok ? eval { JSON::PP->new->utf8->decode($body) } : undef;
    if (ref($la) ne 'HASH') {
        $cs->{katalog_retry_at} = $now + KURZ_RETRY;
        return 0;
    }
    my ($eintraege, $voll) = FM::Chart::katalog_bauen($la, $abruf,
        now => $now, deadline => $lauf_deadline);
    if (!$voll || !@$eintraege) {
        $cs->{katalog_retry_at} = $now + KURZ_RETRY;
        FM::Events::add($rt, 'warn', 'chart', "Miniserver $msno: Katalog unvollstaendig, neuer Versuch folgt", msno => 0);
        return 0;
    }
    my $gen = join('', map { sprintf('%02x', int(rand(256))) } 1 .. 8);
    my @teile;
    push @teile, [ splice(@$eintraege, 0, KATALOG_TEIL) ] while @$eintraege;
    for my $i (0 .. $#teile) {
        my ($st) = FM::Projekt::Upload::_post($cfg, $keyfile, '/api/chart/katalog.php', {
            msno   => $msno + 0,
            gen    => $gen,
            teil   => $teile[$i],
            letzte => ($i == $#teile ? JSON::PP::true : JSON::PP::false),
        });
        if ($st == 403) {
            $cs->{katalog_retry_at} = $now + KATALOG_RETRY;
            say_v("Miniserver $msno: Server nimmt keinen Katalog an (keine Chart-Lizenz)");
            return 2;
        }
        if ($st != 200) {
            $cs->{katalog_retry_at} = $now + KURZ_RETRY;
            say_v("Miniserver $msno: Katalog-Upload scheiterte (HTTP $st)");
            return 0;
        }
    }
    $cs->{katalog_version} = $ver if defined $ver;
    delete $cs->{katalog_retry_at};
    say_v("Miniserver $msno: Katalog uebertragen");
    return 1;
}

my @werte;
my $lesbar = 1;
my $anforderung_offen = 0;
for my $msno (sort { $a <=> $b } keys %miniservers) {
    my $ms   = $miniservers{$msno};
    my $base = FM::Miniserver::base_url($ms);
    my $cred = $ms->{Credentials_RAW};
    my $cs   = ($state->{chart}{$msno} ||= {});
    my $abruf = sub {
        my ($u) = @_;
        return FM::Miniserver::get($base, $cred, "/jdev/sps/io/$u/all");
    };

    my $braucht = FM::Chart::katalog_anforderung_faellig($cs, $now, $anforderung);
    my $angefordert = $braucht;
    if (FM::Chart::version_pruefung_faellig($cs, $now, $anforderung)) {
        my ($vok, $vbody) = FM::Miniserver::get($base, $cred, '/jdev/sps/LoxAPPversion3');
        my $ver = $vok ? FM::Miniserver::ll_value($vbody) : undef;
        $cs->{version_next} = $now + FM::Chart::VERSION_INTERVALL;
        if (!$braucht && defined $ver && $ver ne ''
            && (!defined $cs->{katalog_version} || $cs->{katalog_version} ne $ver)) {
            $braucht = 1;
        }
        if ($braucht) {
            my $res = katalog_hochladen($msno, $base, $cred, $abruf, $ver, $cs);
            $anforderung_offen = 1 if $angefordert && $res == 0;
        }
    } elsif ($braucht) {
        my $res = katalog_hochladen($msno, $base, $cred, $abruf, undef, $cs);
        $anforderung_offen = 1 if $res == 0;
    }

    next if !$erfassen || ref($gruppen->{$msno}) ne 'ARRAY' || !@{ $gruppen->{$msno} };
    my ($w, $fehlt, $voll, $next) = FM::Chart::werte_lesen($gruppen->{$msno}, $abruf,
        deadline => $lauf_deadline, start => $cs->{start} || 0);
    $cs->{start} = $next;
    push @werte, map { { msno => $msno + 0, b => $_->{b}, o => $_->{o}, v => $_->{v} } } @$w;
    $lesbar = 0 if !@$w;
    if ($fehlt && !$cs->{fehlt_gemeldet}) {
        FM::Events::add($rt, 'warn', 'chart', "Miniserver $msno: $fehlt Chart-Werte nicht lesbar", msno => 0);
        $cs->{fehlt_gemeldet} = 1;
    } elsif (!$fehlt) {
        delete $cs->{fehlt_gemeldet};
    }
    if (!$voll && !$cs->{budget_gemeldet}) {
        FM::Events::add($rt, 'warn', 'chart', "Miniserver $msno: Zeitbudget erreicht, Chart-Werte unvollstaendig", msno => 0);
        $cs->{budget_gemeldet} = 1;
    } elsif ($voll) {
        delete $cs->{budget_gemeldet};
    }
    say_v("Miniserver $msno: " . scalar(@$w) . " Werte gelesen, $fehlt nicht lesbar" . ($voll ? '' : ', Zeitbudget erreicht'));
}

FM::Spool::append($rt, { ts => $now, ch => \@werte }) if @werte;
$state->{chart_next} = FM::Chart::naechster($now, $lesbar) if $erfassen;
unlink $reqfile if $anforderung && !$anforderung_offen;
my $frisch = FM::State::load($rt);
for my $k (qw(chart chart_next)) {
    if (exists $state->{$k}) { $frisch->{$k} = $state->{$k}; }
    else                     { delete $frisch->{$k}; }
}
FM::State::save($rt, $frisch);
exit 0;

