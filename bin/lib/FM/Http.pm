# SmartFleet Client
# Copyright (c) 2026 Michael Schlenstedt. Alle Rechte vorbehalten.
# Nutzung, Weitergabe und Veraenderung nur nach den Lizenzbedingungen,
# die diesem Programm beiliegen (LICENSE).

package FM::Http;

use strict;
use warnings;
use HTTP::Tiny;

my $UA;

sub _ua {
    return $UA if $UA;
    if (!eval { require IO::Socket::SSL; 1 }) {
        die "FM::Http: IO::Socket::SSL fehlt - https ist damit nicht moeglich\n";
    }
    $UA = HTTP::Tiny->new(
        agent           => 'fm-agent/1.0',
        timeout         => 30,
        verify_SSL      => 1,
        default_headers => { 'Accept' => 'application/json' },
    );
    return $UA;
}

sub get {
    my ($url) = @_;
    my $r = _ua()->get($url);
    return ($r->{status}, $r->{content}, $r->{headers});
}

sub post_json {
    my ($url, $body, $headers) = @_;
    my %h = ( 'Content-Type' => 'application/json', %{ $headers || {} } );
    my $r = _ua()->request('POST', $url, { content => $body, headers => \%h });
    return ($r->{status}, $r->{content}, $r->{headers});
}

1;

