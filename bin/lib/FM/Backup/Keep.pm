# SmartFleet Client
# Copyright (c) 2026 Michael Schlenstedt. Alle Rechte vorbehalten.
# Nutzung, Weitergabe und Veraenderung nur nach den Lizenzbedingungen,
# die diesem Programm beiliegen (LICENSE).

package FM::Backup::Keep;

use strict;
use warnings;
use File::Spec;
use File::Path qw(remove_tree);

sub ms_dir {
    my ($store, $msno) = @_;
    return File::Spec->catdir($store, 'ms' . ($msno + 0));
}

sub gen_dir {
    my ($store, $msno, $stamp) = @_;
    return File::Spec->catdir(ms_dir($store, $msno), $stamp);
}

sub generations {
    my ($store, $msno) = @_;
    my $d = ms_dir($store, $msno);
    return [] if !-d $d;

    opendir my $dh, $d or return [];
    my @stamps = grep { /\A[0-9]{14}\z/ } readdir $dh;
    closedir $dh;

    my @out;
    for my $s (sort { $b cmp $a } @stamps) {
        my $gd = File::Spec->catdir($d, $s);
        next if !-f File::Spec->catfile($gd, 'backup.zip');
        push @out, { dir => $gd, stamp => $s };
    }
    return \@out;
}

sub prune {
    my ($store, $msno, $keep) = @_;
    $keep = 7 if !defined $keep || $keep < 1;

    my $g = generations($store, $msno);
    return 0 if scalar(@$g) <= $keep;

    my $weg = 0;
    for my $alt (@{$g}[ $keep .. $#$g ]) {
        remove_tree($alt->{dir});
        $weg++ if !-d $alt->{dir};
    }
    return $weg;
}

1;

