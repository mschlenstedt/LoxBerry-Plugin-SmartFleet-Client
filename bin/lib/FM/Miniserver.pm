# SmartFleet Client
# Copyright (c) 2026 Michael Schlenstedt. Alle Rechte vorbehalten.
# Nutzung, Weitergabe und Veraenderung nur nach den Lizenzbedingungen,
# die diesem Programm beiliegen (LICENSE).

package FM::Miniserver;

use strict;
use warnings;
use HTTP::Tiny;
use MIME::Base64 qw(encode_base64);
use JSON::PP;

my $UA;

sub _ua {
    return $UA if $UA;
    $UA = HTTP::Tiny->new(
        agent      => 'fm-agent/1.0',
        timeout    => 10,
        verify_SSL => 0,
    );
    return $UA;
}

sub base_url {
    my ($ms) = @_;
    my $transport = $ms->{Transport} || 'http';
    my $port = ($ms->{PreferHttps} && $ms->{PortHttps})
        ? $ms->{PortHttps}
        : ($ms->{Port} || ($transport eq 'https' ? 443 : 80));
    return $transport . '://' . $ms->{IPAddress} . ':' . $port;
}

sub ll_value {
    my ($raw) = @_;
    return undef if !defined $raw || $raw eq '';
    return $1 if $raw =~ /"value"\s*:\s*"([^"]*)"/;
    return $1 if $raw =~ /"value"\s*:\s*([0-9.eE+-]+)/;
    return undef;
}

sub parse_value {
    my ($pick, $raw) = @_;
    return undef if !defined $pick || !defined $raw;

    if ($pick eq 'number') {
        return $raw =~ /(-?[0-9]+(?:\.[0-9]+)?)/ ? $1 + 0 : undef;
    }
    if ($pick eq 'heapfree') {
        return $raw =~ m{^\s*(-?[0-9]+(?:\.[0-9]+)?)\s*/} ? $1 + 0 : undef;
    }
    if ($pick eq 'heaptotal') {
        return $raw =~ m{/\s*(-?[0-9]+(?:\.[0-9]+)?)} ? $1 + 0 : undef;
    }
    if ($pick eq 'spsfreq') {
        return $raw =~ m{([0-9]+(?:\.[0-9]+)?)\s*/\s*sec} ? $1 + 0 : undef;
    }
    if ($pick eq 'tempcpu' || $pick eq 'tempstm32') {
        return $raw =~ /(-?[0-9]+(?:\.[0-9]+)?)/ ? $1 + 0 : undef;
    }
    return undef;
}

sub get {
    my ($base, $cred, $path) = @_;
    my %headers;
    if (defined $cred && $cred ne '') {
        my $b = encode_base64($cred, '');
        $headers{Authorization} = "Basic $b";
    }
    my $r = _ua()->get($base . $path, { headers => \%headers });
    return (0, undef) if !$r->{success};
    return (1, $r->{content});
}

sub collect {
    my ($ms, $metrics, %opt) = @_;
    my $base = base_url($ms);
    my $cred = $ms->{Credentials_RAW};
    my $dm   = $opt{device_monitor_uuid};

    my (%values, @missing);
    my $antworten = 0;

    for my $m (@$metrics) {
        my $path = $m->{path};
        if ($path eq 'DEVICEMONITOR') {
            if (!$dm) { push @missing, $m->{key}; next; }
            $path = "/jdev/sps/io/$dm/all";
        }
        my ($ok, $body) = get($base, $cred, $path);
        if (!$ok) { push @missing, $m->{key}; next; }
        $antworten++;
        my $v = parse_value($m->{pick}, ll_value($body));
        if (defined $v) { $values{ $m->{key} } = $v; }
        else            { push @missing, $m->{key}; }
    }

    return (\%values, \@missing, ($antworten > 0 ? 1 : 0));
}

sub identity {
    my ($ms, $app_version) = @_;
    my $base = base_url($ms);
    my $cred = $ms->{Credentials_RAW};

    my ($ok, $body) = get($base, $cred, '/data/LoxAPP3.json');
    return { ok => 0, app_version => $app_version } if !$ok;

    my $d = eval { JSON::PP->new->decode($body) };
    return { ok => 0, app_version => $app_version } if !$d || ref($d->{msInfo}) ne 'HASH';

    my $i = $d->{msInfo};
    return {
        ok                  => 1,
        app_version         => $app_version,
        serial              => $i->{serialNr},
        mstype              => $i->{miniserverType},
        name                => $i->{msName},
        project             => $i->{projectName},
        device_monitor_uuid => $i->{deviceMonitor},
        controls            => (ref $d->{controls} eq 'HASH' ? scalar(keys %{ $d->{controls} }) : 0),
    };
}

1;

