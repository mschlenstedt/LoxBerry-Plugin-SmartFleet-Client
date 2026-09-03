# SmartFleet Client
# Copyright (c) 2026 Michael Schlenstedt. Alle Rechte vorbehalten.
# Nutzung, Weitergabe und Veraenderung nur nach den Lizenzbedingungen,
# die diesem Programm beiliegen (LICENSE).

package FM::Collect;

use strict;
use warnings;
use Time::HiRes ();
use FM::Miniserver;

use constant IDENT_RETRY => 3600;

sub due {
    my ($state, $now, $interval) = @_;
    $interval = 300 if !$interval || $interval < 1;
    my $next = $state->{collect_next};
    return 1 if !defined $next;
    return 1 if $next > $now + $interval * 5;
    return $next <= $now ? 1 : 0;
}

sub identity_due {
    my ($cached, $app_version, $now) = @_;
    return 0 if !defined $app_version || $app_version eq '';
    if (defined $now && ref($cached) eq 'HASH'
        && defined $cached->{ident_retry_at}
        && $cached->{ident_retry_at} =~ /\A[0-9]+\z/) {
        my $bis = $cached->{ident_retry_at} + 0;
        return 0 if $now < $bis && $bis <= $now + IDENT_RETRY * 5;
    }
    return 1 if !$cached || ref($cached) ne 'HASH' || !%$cached;
    return 1 if !defined $cached->{app_version};
    return $cached->{app_version} ne $app_version ? 1 : 0;
}

sub remember_identity {
    my ($cache, $msno, $ident, $now) = @_;
    if (ref($ident) eq 'HASH' && $ident->{ok}) {
        my %e = %$ident;
        delete $e{ok};
        $cache->{$msno} = \%e;
        return 1;
    }
    my $e = ref($cache->{$msno}) eq 'HASH' ? $cache->{$msno} : {};
    $e->{ident_retry_at} = int($now) + IDENT_RETRY;
    $cache->{$msno} = $e;
    return 0;
}

sub miniserver_record {
    my ($ms, $msno, $metrics, $cache, $now, %opt) = @_;
    my $will_inventar = exists $opt{inventory} ? ($opt{inventory} ? 1 : 0) : 1;
    $cache = {} if ref($cache) ne 'HASH';

    my $cached = ref($cache->{$msno}) eq 'HASH' ? $cache->{$msno} : {};
    my %rec = (msno => $msno + 0, v => {});
    my @missing;
    my $reachable;

    if ($metrics && @$metrics) {
        my $t0 = Time::HiRes::time();
        my ($values, $miss, $ok) = FM::Miniserver::collect(
            $ms, $metrics, device_monitor_uuid => $cached->{device_monitor_uuid});
        $rec{rt_ms} = int((Time::HiRes::time() - $t0) * 1000);
        $rec{v}     = $values;
        @missing    = @$miss;
        $reachable  = $ok;
    }

    if ($will_inventar) {
        my ($vok, $vbody) = FM::Miniserver::get(
            FM::Miniserver::base_url($ms), $ms->{Credentials_RAW},
            '/jdev/sps/LoxAPPversion3');
        my $app_version = $vok ? FM::Miniserver::ll_value($vbody) : undef;
        $reachable = ($vok ? 1 : 0) if !defined $reachable;

        if (identity_due($cached, $app_version, $now)) {
            my $ident = FM::Miniserver::identity($ms, $app_version);
            remember_identity($cache, $msno, $ident, $now);
            $cached = ref($cache->{$msno}) eq 'HASH' ? $cache->{$msno} : {};
        }
    }

    $rec{reachable} = defined $reachable ? $reachable : 0;
    $rec{ident} = {
        name      => $cached->{name},
        serial    => $cached->{serial},
        mstype    => $cached->{mstype},
        project   => $cached->{project},
        controls  => $cached->{controls},
        location  => $cached->{location},
        latitude  => $cached->{latitude},
        longitude => $cached->{longitude},
    };
    return (\%rec, \@missing);
}

sub build_record {
    my ($now, $lb, $ms) = @_;
    return {
        ts => $now + 0,
        lb => ($lb && ref($lb) eq 'HASH' ? $lb : {}),
        ms => ($ms && ref($ms) eq 'ARRAY' ? $ms : []),
    };
}

1;

