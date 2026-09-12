#!/usr/bin/perl
# SmartFleet Client
# Copyright (c) 2026 Michael Schlenstedt. Alle Rechte vorbehalten.
# Nutzung, Weitergabe und Veraenderung nur nach den Lizenzbedingungen,
# die diesem Programm beiliegen (LICENSE).

use strict;
use warnings;
use Getopt::Long;
use File::Spec;
use File::Path qw(make_path remove_tree);

use FindBin qw($Bin);
use lib "$Bin/lib", "$Bin/../lib";

use FM::Paths;
use FM::Config;
use FM::State;
use FM::Loxlog;
use FM::Miniserver;
use FM::Backup::Fetch;
use FM::Backup::Pack;
use FM::Loxplan;
use FM::Projekt::Upload;
use FM::Events;

use constant MAX_PROJEKT_GROESSE => 67108864;

my ($dir, $msno_wahl, $verbose);
GetOptions(
    'dir=s'  => \$dir,
    'msno=i' => \$msno_wahl,
    'verbose' => \$verbose,
) or die "Aufruf: fm_projekt.pl --dir <konfigdir> [--msno N] [--verbose]\n";
die "fm_projekt: --dir fehlt\n" if !$dir;

my $rt = FM::Paths::laufzeit($dir);
FM::Paths::uebernehmen($dir);

my $cfg = FM::Config::load($dir);
if (!$cfg->{site} || !$cfg->{server}) {
    say_v('Dieser Standort ist noch nicht angemeldet. fm_enroll.pl zuerst ausfuehren.');
    exit 0;
}
my $keyfile = FM::Config::keyfile($dir);

my $log;
sub say_v    { print "$_[0]\n" if $verbose; FM::Loxlog::inf($log, $_[0]); }
sub say_ok   { print "$_[0]\n" if $verbose; FM::Loxlog::ok($log, $_[0]); }
sub say_warn { print "$_[0]\n" if $verbose; FM::Loxlog::warn($log, $_[0]); }
sub say_err  { print "$_[0]\n" if $verbose; FM::Loxlog::err($log, $_[0]); }
sub say_deb  { print "$_[0]\n" if $verbose; FM::Loxlog::deb($log, $_[0]); }
sub log_oeffnen { return if $log; $log = FM::Loxlog::start('projekt', 'Programmsicherung laeuft'); }

my $lock = FM::State::lock($rt, 'projekt');
if (!$lock) {
    say_v('Eine Programmsicherung laeuft bereits - die Sperre ist belegt.');
    exit 0;
}

my $state = FM::State::load($rt);
$state->{projekt} = {} if ref($state->{projekt}) ne 'HASH';

my $ok_lb = eval {
    require LoxBerry::System;
    no strict 'refs';
    die "get_miniservers fehlt\n"
        if !defined &{"LoxBerry::System::get_miniservers"};
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
if (!%miniservers) {
    say_v('Kein lokal angebundener Miniserver konfiguriert.');
    exit 0;
}

my $fehler_gesamt = 0;

for my $msno (sort { $a <=> $b } keys %miniservers) {
    next if defined $msno_wahl && $msno != $msno_wahl;
    my $ms   = $miniservers{$msno};
    my $base = FM::Miniserver::base_url($ms);
    my $cred = $ms->{Credentials_RAW};

    my ($vok, $vbody) = FM::Miniserver::get($base, $cred, '/jdev/sps/LoxAPPversion3',
        sub { say_deb("Miniserver $msno: $_[0]") });
    if (!$vok) {
        say_v("Miniserver $msno: nicht erreichbar");
        next;
    }
    my $app_version = FM::Miniserver::ll_value($vbody);
    if (!defined $app_version || $app_version eq '') {
        say_v("Miniserver $msno: LoxAPPversion3 nicht lesbar");
        next;
    }
    my $bekannt = $state->{projekt}{$msno}{app_version};
    if (!FM::Loxplan::app_version_geaendert($bekannt, $app_version)) {
        say_v("Miniserver $msno: Programm unveraendert");
        next;
    }

    log_oeffnen();
    say_v("Miniserver $msno: Programmaenderung erkannt");

    my ($lok, $lbody) = FM::Miniserver::get($base, $cred, '/dev/fslist/prog',
        sub { say_deb("Miniserver $msno: $_[0]") });
    if (!$lok) {
        FM::Events::add($rt, 'warn', 'projekt', "Miniserver $msno: Programmverzeichnis nicht auflistbar", msno => 0);
        say_warn("Miniserver $msno: /prog nicht auflistbar");
        $fehler_gesamt++;
        next;
    }
    my $eintraege = FM::Backup::Fetch::parse_list($lbody);
    my $datei = FM::Loxplan::waehle_projektdatei($eintraege);
    if (!defined $datei) {
        FM::Events::add($rt, 'warn', 'projekt', "Miniserver $msno: kein Programmstand gefunden", msno => 0);
        say_warn("Miniserver $msno: kein Programmstand gefunden");
        $fehler_gesamt++;
        next;
    }

    my ($groesse_gefunden) = map { $_->{size} } grep { $_->{name} eq $datei } @$eintraege;
    if (defined $groesse_gefunden && $groesse_gefunden > MAX_PROJEKT_GROESSE) {
        my $meldung = sprintf('Miniserver %d: Programmdatei zu gross (%.1f MB, Grenze %.1f MB)',
            $msno, $groesse_gefunden / 1048576, MAX_PROJEKT_GROESSE / 1048576);
        FM::Events::add($rt, 'warn', 'projekt', $meldung, msno => 0);
        say_warn($meldung);
        $fehler_gesamt++;
        next;
    }

    my $arbeitsdir = File::Spec->catdir($rt, 'projekt', "ms$msno");
    remove_tree($arbeitsdir) if -d $arbeitsdir;
    make_path($arbeitsdir);

    my $rohziel = File::Spec->catfile($arbeitsdir, $datei);
    my ($got, undef) = FM::Backup::Fetch::get_to_file($base, $cred, "/prog/$datei", $rohziel,
        sub { say_deb("Miniserver $msno: $_[0]") });
    if (!$got) {
        FM::Events::add($rt, 'warn', 'projekt', "Miniserver $msno: $datei nicht holbar", msno => 0);
        say_warn("Miniserver $msno: $datei nicht holbar");
        $fehler_gesamt++;
        remove_tree($arbeitsdir);
        next;
    }

    my ($eok, $eziel_oder_fehler) = FM::Loxplan::entpacke($rohziel, $arbeitsdir);
    if (!$eok) {
        FM::Events::add($rt, 'warn', 'projekt', "Miniserver $msno: Entpacken fehlgeschlagen - $eziel_oder_fehler", msno => 0);
        say_warn("Miniserver $msno: Entpacken fehlgeschlagen - $eziel_oder_fehler");
        $fehler_gesamt++;
        remove_tree($arbeitsdir);
        next;
    }
    my $loxone  = $eziel_oder_fehler;
    my $groesse = -s $loxone;
    my $sha256  = FM::Backup::Pack::sha256_file($loxone);
    my $metadaten = FM::Loxplan::metadaten($loxone);

    my ($jok, $jbody) = FM::Miniserver::get($base, $cred, '/data/LoxAPP3.json',
        sub { say_deb("Miniserver $msno: $_[0]") });
    if (!$jok) {
        say_deb("Miniserver $msno: LoxAPP3.json nicht holbar - wird ohne sie hochgeladen");
    }
    my $loxapp3 = $jok ? $jbody : undef;

    if ($cfg->{site} && $cfg->{server}) {
        my ($lage, $meldung) = FM::Projekt::Upload::hochladen(
            $cfg, $keyfile, $msno, $app_version, $groesse, $sha256, $loxone,
            $metadaten, $loxapp3, \&say_v, \&say_deb);
        if ($lage eq 'error') {
            FM::Events::add($rt, 'error', 'projekt', "Miniserver $msno: Uebertragung fehlgeschlagen - $meldung", msno => 0);
            say_err("Miniserver $msno: Uebertragung fehlgeschlagen - $meldung");
            $fehler_gesamt++;
        } else {
            $state->{projekt}{$msno}{app_version} = $app_version;
            FM::State::save($rt, $state);
            FM::Events::add($rt, 'info', 'projekt', "Miniserver $msno: Programm aktualisiert", msno => 0);
            say_ok("Miniserver $msno: Programm hochgeladen ($groesse Byte)");
        }
    }

    remove_tree($arbeitsdir);
}

FM::Loxlog::ende($log);
exit($fehler_gesamt > 0 ? 1 : 0);

