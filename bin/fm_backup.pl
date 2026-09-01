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
use File::Temp qw(tempdir);
use JSON::PP;
use Cwd qw(getcwd);

use FindBin qw($Bin);
use lib "$Bin/lib", "$Bin/../lib";

use FM::Paths;
use FM::Config;
use FM::Settings;
use FM::State;
use FM::Loxlog;
use FM::Cron;
use FM::Miniserver;
use FM::Backup::Catalog;
use FM::Backup::Fetch;
use FM::Backup::Pack;
use FM::Backup::Keep;
use FM::Events;

use constant MIN_FREI => 200 * 1024 * 1024;

my ($dir, $store, $msno_wahl, $force, $dry, $verbose);
GetOptions(
    'dir=s'   => \$dir,
    'store=s' => \$store,
    'msno=i'  => \$msno_wahl,
    'force'   => \$force,
    'dry-run' => \$dry,
    'verbose' => \$verbose,
) or die "Aufruf: fm_backup.pl --dir <konfigdir> --store <ablage> [--msno N] [--force] [--dry-run] [--verbose]\n";
die "fm_backup: --dir fehlt\n"   if !$dir;
my $rt = FM::Paths::laufzeit($dir);
FM::Paths::uebernehmen($dir);

if (!$store) {
    my $cfg0 = FM::Config::load($dir);
    $store = FM::Settings::get($dir, 'backup_store', $cfg0);
}
if (!$store) {
    print "Keine Sicherungsablage eingestellt - es wird nicht gesichert." . chr(10) if $verbose;
    exit 0;
}

my $log;
sub say_v {
    print "$_[0]\n" if $verbose;
    FM::Loxlog::inf($log, $_[0]);
}

sub log_oeffnen {
    return if $log;
    $log = FM::Loxlog::start('backup', 'Sicherung laeuft');
}

my $lock = FM::State::lock($rt, 'backup');
if (!$lock) {
    say_v('Ein Backup laeuft bereits - die Sperre ist belegt.');
    exit 0;
}

my $state = FM::State::load($rt);
my $now   = time();

my $desired = ref($state->{desired}) eq 'HASH' ? $state->{desired} : {};
my $bcfg    = ref($desired->{backup}) eq 'HASH' ? $desired->{backup} : {};
my $cron    = $bcfg->{cron};
my $keep    = ($bcfg->{keep} && $bcfg->{keep} =~ /\A[0-9]+\z/) ? $bcfg->{keep} + 0 : 7;
my $scope   = ref($bcfg->{scope}) eq 'HASH' ? $bcfg->{scope} : FM::Backup::Catalog::DEFAULT_SCOPE();

if (!$force && !$dry) {
    if (!defined $cron || $cron eq '') {
        say_v('Kein Zeitplan im Sollzustand - es wird nicht gesichert.');
        exit 0;
    }
    if (!FM::Cron::due($cron, $now, $state->{backup_last})) {
        say_v('Zeitplan noch nicht faellig.');
        exit 0;
    }
}

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
if (!%miniservers) {
    say_v('Kein Miniserver konfiguriert.');
    exit 0;
}

my $cfg     = FM::Config::load($dir);
my $encrypt = $bcfg->{encrypt} ? 1 : 0;
my $pw      = $cfg->{tunnel_password};

if ($encrypt && (!defined $pw || $pw eq '')) {
    FM::Events::add($rt, 'error', 'backup',
        'Verschluesselung verlangt, aber kein Passwort hinterlegt');
    say_v('Verschluesselung verlangt, aber kein Passwort hinterlegt.');
    exit 0;
}
if ($encrypt && !FM::Backup::Pack::have_7z()) {
    FM::Events::add($rt, 'error', 'backup',
        'Verschluesselung verlangt, aber 7z fehlt - es wird NICHT unverschluesselt gesichert');
    say_v('Verschluesselung verlangt, aber 7z fehlt.');
    exit 0;
}

aufraeumen($store, $now);

my $frei = freier_platz($store);
if (defined $frei && $frei < MIN_FREI) {
    FM::Events::add($rt, 'error', 'backup',
        sprintf('Zu wenig Platz: %d MB frei, %d MB noetig',
                int($frei / 1048576), int(MIN_FREI() / 1048576)));
    log_oeffnen();
    say_v(sprintf('Zu wenig Platz in der Ablage: %d MB frei', int($frei / 1048576)));
    exit 0;
}

if (!$dry) {
    $state->{backup_last} = $now;
    FM::State::save($rt, $state);
}

my $fehler_gesamt = 0;

for my $msno (sort { $a <=> $b } keys %miniservers) {
    next if defined $msno_wahl && $msno != $msno_wahl;

    my $ms   = $miniservers{$msno};
    my $base = FM::Miniserver::base_url($ms);
    my $cred = $ms->{Credentials_RAW};

    log_oeffnen();
    say_v("Miniserver $msno: Auflisten");
    my $dirs = FM::Backup::Catalog::scope_dirs($scope);
    my ($dateien, $fehler) = FM::Backup::Fetch::walk($base, $cred, $dirs);

    if (@$fehler) {
        say_v("Miniserver $msno: " . $fehler->[0]);
        $fehler_gesamt++;
        next;
    }
    say_v("Miniserver $msno: " . scalar(@$dateien) . ' Dateien');

    if ($dry) {
        say_v("Miniserver $msno: Trockenlauf - nichts abgelegt");
        next;
    }

    my $tmp = eval { tempdir(DIR => $store, CLEANUP => 1) };
    if (!$tmp) {
        say_v("Miniserver $msno: Ablage $store nicht beschreibbar");
        $fehler_gesamt++;
        next;
    }
    my $inhalt = File::Spec->catdir($tmp, 'inhalt');
    make_path($inhalt);

    my (@erfasst, @fehlend);
    for my $d (@$dateien) {
        my $ziel = File::Spec->catfile($inhalt, split m{/}, substr($d->{path}, 1));
        my ($vd) = $ziel =~ m{\A(.*)[/\\][^/\\]+\z};
        make_path($vd) if $vd && !-d $vd;

        my ($got, $bytes) =
            FM::Backup::Fetch::get_to_file($base, $cred, $d->{path}, $ziel);
        if (!$got) {
            push @fehlend, $d->{path};
            next;
        }
        push @erfasst, { path => $d->{path}, size => $bytes,
                         sha256 => FM::Backup::Pack::sha256_file($ziel) };
    }

    if (!@erfasst) {
        FM::Events::add($rt, 'error', 'backup',
                        'Keine einzige Datei holbar', msno => $msno);
        say_v("Miniserver $msno: keine einzige Datei holbar");
        $fehler_gesamt++;
        next;
    }

    if (@fehlend || @$fehler) {
        my $text = sprintf('%d von %d Dateien nicht gesichert',
                           scalar(@fehlend),
                           scalar(@fehlend) + scalar(@erfasst));
        $text .= sprintf(', %d Verzeichnisse nicht lesbar', scalar @$fehler)
            if @$fehler;
        FM::Events::add($rt, 'warn', 'backup', $text, msno => $msno);
        say_v("Miniserver $msno: $text");
    }

    my $fp = FM::Backup::Pack::fingerprint(\@erfasst, $encrypt);

    my $gens = FM::Backup::Keep::generations($store, $msno);
    if (@$gens) {
        my $mf = File::Spec->catfile($gens->[0]{dir}, 'meta.json');
        my $alt = eval {
            open my $fh, '<', $mf or die;
            local $/;
            JSON::PP->new->decode(scalar <$fh>);
        };
        if ($alt && ($alt->{fingerprint} // '') eq $fp) {
            say_v("Miniserver $msno: unveraendert - keine neue Generation");
            next;
        }
    }

    my $zip = File::Spec->rel2abs(File::Spec->catfile($tmp, 'backup.zip'));
    my $vorher = getcwd();
    chdir $inhalt or do {
        say_v("Miniserver $msno: chdir fehlgeschlagen");
        $fehler_gesamt++;
        next;
    };
    my ($zok, $zsize, $zfehler);
    if ($encrypt) {
        ($zok, $zsize, $zfehler) =
            FM::Backup::Pack::make_zip_encrypted('.', $zip, $pw);
    } else {
        ($zok, $zsize) = FM::Backup::Pack::make_zip('.', $zip);
    }
    chdir $vorher;

    if (!$zok) {
        say_v("Miniserver $msno: Packen fehlgeschlagen"
              . ($zfehler ? " - $zfehler" : ' - ist zip vorhanden?'));
        $fehler_gesamt++;
        next;
    }

    my @g = gmtime($now);
    my $stamp = sprintf('%04d%02d%02d%02d%02d%02d',
                        $g[5] + 1900, $g[4] + 1, $g[3], $g[2], $g[1], $g[0]);

    my $meta = {
        v => 1, msno => $msno + 0, ts => $now + 0,
        scope => $scope,
        encrypt => $encrypt,
        fingerprint => $fp,
        sha256 => FM::Backup::Pack::sha256_file($zip),
        size => $zsize + 0,
        files => scalar(@erfasst),
        complete => ((@fehlend || @$fehler) ? 0 : 1),
        missing  => [ @fehlend[0 .. (scalar(@fehlend) > 50 ? 49 : $#fehlend)] ],
        uploaded => 0,
    };
    open my $mfh, '>', File::Spec->catfile($tmp, 'meta.json') or do {
        say_v("Miniserver $msno: meta.json nicht schreibbar");
        $fehler_gesamt++;
        next;
    };
    print {$mfh} JSON::PP->new->canonical->encode($meta);
    close $mfh;

    remove_tree($inhalt);

    my $ziel_gen = FM::Backup::Keep::gen_dir($store, $msno, $stamp);
    make_path(FM::Backup::Keep::ms_dir($store, $msno));
    if (!rename($tmp, $ziel_gen)) {
        say_v("Miniserver $msno: Generation konnte nicht an den Platz");
        $fehler_gesamt++;
        next;
    }

    my $weg = FM::Backup::Keep::prune($store, $msno, $keep);
    say_v(sprintf('Miniserver %d: Generation %s, %.2f MB, %d Dateien%s',
                  $msno, $stamp, $zsize / 1048576, scalar(@erfasst),
                  $weg ? ", $weg weggerollt" : ''));
}

exit 0;

sub freier_platz {
    my ($pfad) = @_;
    return undef if !-d $pfad;
    my @z = qx{df -kP "$pfad" 2>/dev/null};
    return undef if scalar(@z) < 2;
    my @f = split /\s+/, $z[1];
    return undef if scalar(@f) < 4 || $f[3] !~ /\A[0-9]+\z/;
    return $f[3] * 1024;
}

sub aufraeumen {
    my ($store, $now) = @_;
    return if !-d $store;

    opendir my $sh, $store or return;
    my @oben = grep { !/\A\.\.?\z/ } readdir $sh;
    closedir $sh;

    for my $e (@oben) {
        my $p = File::Spec->catdir($store, $e);
        next if !-d $p;

        if ($e =~ /\Ams[0-9]+\z/) {
            opendir my $mh, $p or next;
            my @gen = grep { /\A[0-9]{14}\z/ } readdir $mh;
            closedir $mh;
            for my $g (@gen) {
                my $gp = File::Spec->catdir($p, $g);
                remove_tree($gp)
                    if !-f File::Spec->catfile($gp, 'backup.zip');
            }
            next;
        }

        my $alter = $now - (stat($p))[9];
        remove_tree($p) if $alter > 86400;
    }
}

FM::Loxlog::ende($log);

