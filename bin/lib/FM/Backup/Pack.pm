# SmartFleet Client
# Copyright (c) 2026 Michael Schlenstedt. Alle Rechte vorbehalten.
# Nutzung, Weitergabe und Veraenderung nur nach den Lizenzbedingungen,
# die diesem Programm beiliegen (LICENSE).

package FM::Backup::Pack;

use strict;
use warnings;
use Digest::SHA qw(sha256_hex);

sub sha256_file {
    my ($pfad) = @_;
    return undef if !defined $pfad || !-f $pfad;
    my $d = eval { Digest::SHA->new(256)->addfile($pfad, 'b')->hexdigest };
    return $d;
}

sub fingerprint {
    my ($dateien, $encrypt) = @_;
    return sha256_hex('') if !$dateien || ref($dateien) ne 'ARRAY';

    my @zeilen;
    for my $d (@$dateien) {
        next if ref($d) ne 'HASH' || !defined $d->{path};
        push @zeilen, join("\0", $d->{path},
                                 defined $d->{size} ? $d->{size} : 0,
                                 defined $d->{sha256} ? $d->{sha256} : '')
                    . "\n";
    }
    push @zeilen, "\0encrypt\0" . ($encrypt ? 1 : 0) . "\n";
    return sha256_hex(join '', sort @zeilen);
}

sub make_zip {
    my ($quelldir, $zieldatei) = @_;
    return (0, 0) if !-d $quelldir;

    unlink $zieldatei if -e $zieldatei;
    my $rc = system('zip', '-q', '-r', '-X', $zieldatei, '.', '-i', '*');
    if ($rc != 0) {
        unlink $zieldatei if -e $zieldatei;
        return (0, 0);
    }
    my $sz = -s $zieldatei;
    return (0, 0) if !$sz;
    return (1, $sz);
}

sub have_7z {
    my $rc = system('sh', '-c', 'command -v 7z >/dev/null 2>&1');
    return $rc == 0 ? 1 : 0;
}

sub make_zip_encrypted {
    my ($quelldir, $zieldatei, $passwort) = @_;
    return (0, 0, 'kein Quellverzeichnis') if !-d $quelldir;
    return (0, 0, 'leeres Passwort')
        if !defined $passwort || $passwort eq '';
    return (0, 0, '7z fehlt') if !have_7z();

    unlink $zieldatei if -e $zieldatei;

    my $rc = system('7z', 'a', '-tzip', '-mem=AES256',
                    '-p' . $passwort, '-bso0', '-bsp0',
                    $zieldatei, $quelldir);
    if ($rc != 0) {
        unlink $zieldatei if -e $zieldatei;
        return (0, 0, "7z meldete $rc");
    }
    my $sz = -s $zieldatei;
    return (0, 0, 'leeres Paket') if !$sz;
    return (1, $sz, undef);
}

1;

