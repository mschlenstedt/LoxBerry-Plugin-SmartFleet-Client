# SmartFleet Client
# Copyright (c) 2026 Michael Schlenstedt. Alle Rechte vorbehalten.
# Nutzung, Weitergabe und Veraenderung nur nach den Lizenzbedingungen,
# die diesem Programm beiliegen (LICENSE).

package FM::Roots;

use strict;
use warnings;
use FM::B64 qw(b64u_decode);

our %ROOTS_B64 = (
);

sub roots {
    my %out;
    for my $id (keys %ROOTS_B64) {
        next if !$ROOTS_B64{$id};
        $out{$id} = b64u_decode($ROOTS_B64{$id});
    }
    return \%out;
}

1;

