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
use Digest::SHA qw(sha256);
use FM::B64 qw(b64u_encode b64u_decode);
use FM::Config;
use FM::Loxlog;
use FM::Keys;
use FM::Cert;
use FM::Http;
use FM::Roots;

sub _sitename {
    my ($cfg) = @_;
    return $cfg->{name} if $cfg->{name};
    my $name = eval {
        require LoxBerry::System;
        LoxBerry::System->import(qw(lbhostname));
        return lbhostname();
    };
    if (!defined $name || $name eq '') {
        $name = `hostname`;
        chomp $name if defined $name;
    }
    return (defined $name && $name ne '') ? $name : 'LoxBerry';
}

my ($dir, $code, $force);
GetOptions('dir=s' => \$dir, 'code=s' => \$code, 'force' => \$force)
    or die "Aufruf: fm_enroll.pl --dir <konfigdir> --code <bereitstellungscode> [--force]\n";
die "fm_enroll: --dir fehlt\n"  if !$dir;
die "fm_enroll: --code fehlt\n" if !$code;

my $log = FM::Loxlog::start('connect', 'Verbindung zum Server wird aufgebaut');
sub sag {
    my $text = "@_";
    print "$text\n";
    FM::Loxlog::inf($log, $text);
}

my $cfg = FM::Config::load($dir);
if ($cfg->{site} && !$force) {
    die "fm_enroll: dieser Standort ist bereits angemeldet ($cfg->{site}).\n"
      . "Mit --force wird die Anmeldung ersetzt - der alte Standort bleibt auf dem\n"
      . "Server bestehen und muss dort geloescht werden.\n";
}

my $p = FM::Config::parse_code($code);
FM::Loxlog::deb($log, "Code entschluesselt, Serveradresse: $p->{url}");
sag("Server: $p->{url}");

my $keyfile = FM::Config::keyfile($dir);
if (-e $keyfile && !$force) {
    sag("Vorhandenen Schluessel wiederverwenden.");
} else {
    FM::Keys::generate($keyfile);
    sag("Neues Schluesselpaar erzeugt.");
}
my $pub = FM::Keys::public_raw($keyfile);

my ($st, $body) = FM::Http::get("$p->{url}/api/v1/hello");
die "fm_enroll: hello antwortet mit HTTP $st\n" if $st != 200;
my $hello = eval { JSON::PP->new->decode($body) }
    or die "fm_enroll: hello liefert kein gueltiges JSON\n";

my $srv_leaf = eval {
    FM::Cert::verify_chain($hello->{chain}, expect_typ => 'srv', roots => FM::Roots::roots());
};
die "fm_enroll: die Serverkette ist ungueltig: $@" if !$srv_leaf;

my ($srv_cert, $ca_cert) = split /~/, $hello->{chain}, 2;
my $ca_payload = FM::Cert::decode($ca_cert);
my $fp = b64u_encode(sha256(b64u_decode($ca_payload->{pub})));
if ($fp ne $p->{fp}) {
    die "fm_enroll: der Fingerprint der Partner-CA passt nicht zum Bereitstellungscode.\n"
      . "  erwartet: $p->{fp}\n  gefunden: $fp\n"
      . "Abbruch, ohne dass der Token gesendet wurde.\n";
}
sag("Server geprueft: $srv_leaf->{sub} unter $ca_payload->{sub}");

my $pub_b64 = b64u_encode($pub);
my $ts      = time();
my $selfsig = b64u_encode(
    FM::Keys::sign($keyfile, "enroll\n$p->{token}\n$pub_b64\n$ts")
);

my $name = _sitename($cfg);

my $req = JSON::PP->new->canonical->encode({
    v => 1, token => $p->{token}, pub => $pub_b64,
    name => $name, ts => $ts, selfsig => $selfsig,
});
my ($st2, $body2) = FM::Http::post_json("$p->{url}/api/v1/enroll", $req);
die "fm_enroll: enroll antwortet mit HTTP $st2: $body2\n" if $st2 != 200;
my $ans = eval { JSON::PP->new->decode($body2) }
    or die "fm_enroll: enroll liefert kein gueltiges JSON\n";
die "fm_enroll: Server meldet Zustand '$ans->{status}'\n" if ($ans->{status} || '') ne 'issued';

my $leaf = eval {
    FM::Cert::verify_chain($ans->{chain}, expect_typ => 'site',
                           expect_sub => $ans->{site}, roots => FM::Roots::roots());
};
die "fm_enroll: das ausgestellte Zertifikat ist ungueltig: $@" if !$leaf;
die "fm_enroll: das Zertifikat traegt einen fremden Schluessel - Abbruch\n"
    if b64u_decode($leaf->{pub}) ne $pub;

FM::Config::save($dir, {
    %$cfg,
    site        => $ans->{site},
    name        => $name,
    server      => $p->{url},
    path_prefix => FM::Config::path_prefix($p->{url}),
    chain       => $ans->{chain},
    srv_pub     => $srv_leaf->{pub},
    partner     => $ca_payload->{sub},
    enrolled_at => time(),
});

sag("Angemeldet als $ans->{site}");
sag("Gueltig bis " . scalar(gmtime($leaf->{exp})) . " UTC");
FM::Loxlog::ok($log, 'Verbindung hergestellt');
FM::Loxlog::ende($log);
exit 0;

