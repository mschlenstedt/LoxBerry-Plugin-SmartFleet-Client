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
use Time::HiRes qw(time);
use FM::Config;
use FM::Settings;
use FM::State;
use FM::Spool;
use FM::Catalog;
use FM::Miniserver;
use FM::Linfo;
use FM::Collect;

my ($dir, $verbose);
GetOptions('dir=s' => \$dir, 'verbose' => \$verbose)
    or die "Aufruf: fm_collect.pl --dir <konfigdir> [--verbose]\n";
die "fm_collect: --dir fehlt\n" if !$dir;

sub say_v { print "@_\n" if $verbose; }

my $lbwebserverport;
my $get_miniservers;
{
    my $ok = eval {
        require LoxBerry::System;
        {
            no strict 'refs';
            for my $f (qw(lbwebserverport get_miniservers)) {
                die "LoxBerry::System::$f fehlt\n"
                    if !defined &{"LoxBerry::System::$f"};
            }
        }
        $lbwebserverport = \&LoxBerry::System::lbwebserverport;
        $get_miniservers = \&LoxBerry::System::get_miniservers;
        1;
    };
    if (!$ok) {
        say_v('LoxBerry::System ist hier nicht verfuegbar - der Sammler beendet sich.');
        exit 0;
    }
}

my $lock = FM::State::lock($dir, 'collect');
if (!$lock) {
    say_v('Ein anderer Sammellauf ist aktiv - dieser beendet sich.');
    exit 0;
}

my $cfg = FM::Config::load($dir);
if (!$cfg->{site}) {
    say_v('Standort ist nicht angemeldet.');
    exit 0;
}

my $state = FM::State::load($dir);
my $desired = ref($state->{desired}) eq 'HASH' ? $state->{desired} : {};
my $tcfg = ref($desired->{telemetry}) eq 'HASH' ? $desired->{telemetry} : {};
my $interval = $tcfg->{interval} && $tcfg->{interval} >= 60 ? $tcfg->{interval} : 300;

my $lokal = FM::Settings::get($dir, 'collect_interval', $cfg);
$interval = $lokal if $lokal && $lokal >= 60;

my $now = time();
if (!FM::Collect::due($state, $now, $interval)) {
    say_v('Intervall noch nicht erreicht.');
    exit 0;
}
$state->{collect_next} = int($now) + $interval;

FM::State::save($dir, $state);

my $lb_metrics = FM::Catalog::select([ FM::Catalog::loxberry_all() ], $tcfg->{loxberry});
my $lb_values  = {};
if (@$lb_metrics) {
    my $port = $lbwebserverport->() || 80;
    my $lb_url = "http://localhost:$port/system/tools/linfo/index.php?out=json";
    my ($v, $lb_missing, $lb_err) = FM::Linfo::collect($lb_url, $lb_metrics);
    $lb_values = $v;
    say_v("LoxBerry: " . scalar(keys %$lb_values) . " Werte"
          . (@$lb_missing ? ', fehlend: ' . join(',', @$lb_missing) : '')
          . ($lb_err ? " ($lb_err)" : ''));
}
else {
    say_v('LoxBerry-Telemetrie ist fuer diesen Standort abgeschaltet.');
}

my $ms_metrics = FM::Catalog::select([ FM::Catalog::miniserver_all() ], $tcfg->{miniserver});

my $want_inventory = (exists $tcfg->{inventory} && !$tcfg->{inventory}) ? 0 : 1;

my %miniservers = $get_miniservers->();
my @ms_records;

my $ident_cache = ref($state->{ms_ident}) eq 'HASH' ? $state->{ms_ident} : {};

if (!@$ms_metrics && !$want_inventory) {
    say_v('Miniserver-Telemetrie und Inventar sind fuer diesen Standort abgeschaltet.');
}
else {
    for my $msno (sort { $a <=> $b } keys %miniservers) {
        my ($rec, $missing) = FM::Collect::miniserver_record(
            $miniservers{$msno}, $msno, $ms_metrics, $ident_cache, $now,
            inventory => $want_inventory);
        push @ms_records, $rec;
        say_v("Miniserver $msno: " . scalar(keys %{ $rec->{v} }) . " Werte, "
              . "erreichbar=$rec->{reachable}"
              . (@$missing ? ', fehlend: ' . join(',', @$missing) : ''));
    }
}

$state->{ms_ident} = $ident_cache;

FM::Spool::append($dir, FM::Collect::build_record(int($now), $lb_values, \@ms_records));
FM::State::save($dir, $state);
say_v('Spool: ' . FM::Spool::size($dir) . ' Byte');
exit 0;

