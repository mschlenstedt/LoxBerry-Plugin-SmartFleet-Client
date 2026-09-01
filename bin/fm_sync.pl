#!/usr/bin/perl
# SmartFleet Client
# Copyright (c) 2026 Michael Schlenstedt. Alle Rechte vorbehalten.
# Nutzung, Weitergabe und Veraenderung nur nach den Lizenzbedingungen,
# die diesem Programm beiliegen (LICENSE).

use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/lib", "$Bin/../lib";
use Getopt::Long;
use JSON::PP;
use FM::B64 qw(b64u_decode);
use FM::Paths;
use FM::Config;
use FM::Loxlog;
use FM::Settings;
use FM::State;
use FM::Sig;
use FM::Http;
use FM::Jobs qw(run_jobs);
use FM::Selftest;
use FM::Sync;
use FM::Spool;
use FM::Events;
use FM::Backup::Upload;

my ($dir, $verbose, $mit_log);
GetOptions('dir=s' => \$dir, 'verbose' => \$verbose, 'log' => \$mit_log)
    or die "Aufruf: fm_sync.pl --dir <konfigdir> [--verbose]\n";
die "fm_sync: --dir fehlt\n" if !$dir;
my $rt = FM::Paths::laufzeit($dir);
FM::Paths::uebernehmen($dir);

my $log;
sub say_v {
    my $text = "@_";
    print "$text\n" if $verbose;
    FM::Loxlog::inf($log, $text);
}

my $lock = FM::State::lock($rt);
if (!$lock) {
    say_v('Ein anderer Lauf ist noch aktiv - dieser beendet sich.');
    exit 0;
}

$log = FM::Loxlog::start('sync', 'Verbindungstest') if $mit_log;

my $cfg = FM::Config::load($dir);
if (!$cfg->{site} || !$cfg->{server}) {
    say_v('Dieser Standort ist noch nicht angemeldet. fm_enroll.pl zuerst ausfuehren.');
    exit 0;
}

my $state   = FM::State::load($rt);
my $keyfile = FM::Config::keyfile($dir);
my $srv_pub = b64u_decode($cfg->{srv_pub});

my $now = time();
my $selftest;
my $su = eval { $state->{desired}{selftest}{url} };
if ($su && (!$state->{selftest_last} || $now - $state->{selftest_last} > 86400)) {
    my $st = FM::Selftest::run($cfg->{server}, $su);
    if (defined $st) {
        $selftest = { url => $su, status => $st + 0 };
        $state->{selftest_last} = $now;
        say_v("Selbsttest der Backup-Ablage: HTTP $st"
              . ($st == 403 ? ' - gesperrt, wie es sein soll' : ' - ACHTUNG, nicht gesperrt'));
    }
}

system($^X, "$Bin/fm_tunnel.pl", '--dir', $dir, '--enforce');

$state->{seq}++;
my ($samples, $spool_offset) = FM::Sync::take_samples($rt);

my ($events, $ev_offset) = FM::Events::take($rt, FM::Events::MAX_PER_POLL());

my %body = (
    v       => 1,
    seq     => $state->{seq},
    ts      => $now,
    ack     => $state->{pending_acks},
    samples => $samples,
    events  => $events,
);
$body{selftest} = $selftest if $selftest;
my $body = JSON::PP->new->canonical->encode(\%body);

my $path     = '/api/v1/sync';
my $sig_path = ($cfg->{path_prefix} || '') . $path;
my $headers  = FM::Sig::headers($keyfile, $cfg->{site}, 'POST', $sig_path, $body);
my ($st, $resp, $rh) = FM::Http::post_json("$cfg->{server}$path", $body, $headers);

if ($st != 200) {
    $state->{sync_fehler}    = "HTTP $st";
    $state->{sync_fehler_at} = time();
    FM::State::save($rt, $state);
    say_v("Server antwortet mit HTTP $st - naechster Versuch in einer Minute.");
    exit 0;
}

my $rsig = $rh->{'x-fm-sig'};
if (!FM::Sig::verify_response($resp, $rsig, $srv_pub)) {
    FM::State::save($rt, $state);
    die "fm_sync: die Antwortsignatur des Servers stimmt nicht - Antwort verworfen.\n";
}

my $ans = eval { JSON::PP->new->decode($resp) };
if (!$ans) {
    FM::State::save($rt, $state);
    die "fm_sync: der Server liefert kein gueltiges JSON.\n";
}

if ($ev_offset) {
    FM::Events::truncate_to($rt, $ev_offset);
}

$state->{desired} = ref($ans->{desired}) eq 'HASH' ? $ans->{desired} : {};

$state->{pending_acks} = [];

if ($spool_offset) {
    my $gesendet = scalar(@$samples);
    if (!FM::Sync::may_truncate($ans, $gesendet)) {
        say_v("Spool: der Server hat nur " . ($ans->{records} // '?')
              . " von $gesendet Datensaetzen verarbeitet - nicht gekuerzt, "
              . 'der Rest geht beim naechsten Lauf erneut mit.');
    }
    else {
        my $ok = FM::Spool::truncate_to($rt, $spool_offset);
        say_v('Spool: Versatz verfallen - der Stapel geht erneut mit.') if !$ok;
    }
}

my $backup_store = FM::Settings::get($dir, 'backup_store', $cfg);
if ($backup_store) {
    for my $msno (@{ FM::Backup::Upload::msnos($backup_store) }) {
        my ($lage, $meldung) = FM::Backup::Upload::send_one(
            $cfg, $keyfile, $backup_store, $msno, \&say_v);
        last if $lage eq 'partial' || $lage eq 'error';
    }
}

my %HANDLER = (
    ping => sub { return (1, 'pong'); },

    backup_now => sub {
        my ($payload) = @_;
        my $store = FM::Settings::get($dir, 'backup_store', $cfg);
        return (0, 'keine Ablage konfiguriert') if !$store;

        my $msno = (ref($payload) eq 'HASH' && defined $payload->{msno}
                    && $payload->{msno} =~ /\A[0-9]{1,10}\z/)
                 ? $payload->{msno} + 0 : undef;

        my @arg = ($^X, "$Bin/fm_backup.pl",
                   '--dir', $dir, '--store', $store, '--force');
        push @arg, ('--msno', $msno) if defined $msno;

        my $rc = system(@arg);
        return ($rc == 0 ? 1 : 0, $rc == 0 ? 'Backup erzeugt' : "Laeufer meldete $rc");
    },

    tunnel_open => sub {
        my ($job) = @_;
        my $payload = (ref($job) eq 'HASH' && ref($job->{payload}) eq 'HASH')
                    ? $job->{payload} : {};
        my $nonce   = $payload->{nonce};
        my $ts      = defined $payload->{ts} ? "$payload->{ts}" : undef;
        my $antwort = $payload->{antwort};
        return (0, 'Auftrag unvollstaendig')
            if !defined $nonce   || $nonce eq ''
            || !defined $ts      || $ts !~ /\A[0-9]+\z/
            || !defined $antwort || $antwort eq '';

        my @arg = ($^X, "$Bin/fm_tunnel.pl", '--dir', $dir, '--start',
                   '--nonce', $nonce, '--ts', $ts, '--antwort', $antwort);
        my $rc = system(@arg);
        return ($rc == 0 ? 1 : 0, $rc == 0 ? 'Tunnel gestartet' : 'Tunnel nicht gestartet');
    },
);

$state->{pending_acks} = run_jobs($ans->{jobs}, \%HANDLER, \&say_v);

$state->{sync_ok_at} = time();
delete $state->{sync_fehler};
delete $state->{sync_fehler_at};

FM::State::save($rt, $state);
say_v('Sync abgeschlossen, Sequenz ' . $state->{seq});
exit 0;

FM::Loxlog::ende($log);

