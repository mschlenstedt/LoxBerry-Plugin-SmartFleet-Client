# SmartFleet Client
# Copyright (c) 2026 Michael Schlenstedt. Alle Rechte vorbehalten.
# Nutzung, Weitergabe und Veraenderung nur nach den Lizenzbedingungen,
# die diesem Programm beiliegen (LICENSE).

package FM::Chart;

use strict;
use warnings;
use JSON::PP;
use File::Spec;
use File::Temp qw(tempfile);
use File::Copy qw(move);

my %SPERRTYPEN = map { $_ => 1 } qw(virtualtextin virtualintext textstate callervirtualin);

use constant INTERVALL   => 300;
use constant AUSFALL_MAX => 3;
use constant VERSION_INTERVALL => 300;

sub gesperrt_typ {
    my ($typ) = @_;
    return 1 if !defined $typ || $typ eq '';
    return $SPERRTYPEN{ lc $typ } ? 1 : 0;
}

sub zahl_mit_einheit {
    my ($s) = @_;
    return () if !defined $s || ref($s) ne '';
    return () if $s !~ /\A\s*(-?\d+(?:\.\d+)?(?:[eE][-+]?\d+)?)\s*([^\s\d]\D{0,11})?\s*\z/;
    my ($z, $e) = ($1, defined $2 ? $2 : '');
    $e =~ s/\s+\z//;
    return ($z + 0, $e);
}

sub _nr { my ($k) = @_; return $k =~ /(\d+)\z/ ? $1 + 0 : 0; }

sub parse_all {
    my ($body) = @_;
    return undef if !defined $body;
    my $d = eval { JSON::PP->new->utf8->decode($body) };
    return undef if ref($d) ne 'HASH' || ref($d->{LL}) ne 'HASH';
    my $ll = $d->{LL};
    return undef if !defined $ll->{Code} || $ll->{Code} ne '200';
    my @aus;
    for my $k (sort { _nr($a) <=> _nr($b) } grep { /\Aoutput\d+\z/ } keys %$ll) {
        my $o = $ll->{$k};
        next if ref($o) ne 'HASH' || !defined $o->{name} || $o->{name} !~ /\A[A-Za-z0-9_]{1,32}\z/;
        my $v = $o->{value};
        next if !defined $v || ref($v) ne '';
        next if $v !~ /\A-?\d+(?:\.\d+)?(?:[eE][-+]?\d+)?\z/;
        push @aus, [ $o->{name}, $v + 0, '' ];
    }
    return \@aus if @aus;
    my ($z, $e) = zahl_mit_einheit($ll->{value});
    return defined $z ? [ [ 'value', $z, $e ] ] : [];
}

sub katalog_bauen {
    my ($la, $abruf, %opt) = @_;
    my $now      = $opt{now} || time();
    my $deadline = $opt{deadline};
    my (%raum, %kat);
    if (ref($la->{rooms}) eq 'HASH') {
        $raum{$_} = $la->{rooms}{$_}{name} for grep { ref($la->{rooms}{$_}) eq 'HASH' } keys %{ $la->{rooms} };
    }
    if (ref($la->{cats}) eq 'HASH') {
        $kat{$_} = $la->{cats}{$_}{name} for grep { ref($la->{cats}{$_}) eq 'HASH' } keys %{ $la->{cats} };
    }
    my (@eintraege, $fehler, $consec);
    my $vollstaendig = 1;
    $fehler = 0;
    $consec = 0;
    my $controls = ref($la->{controls}) eq 'HASH' ? $la->{controls} : {};
    for my $uuid (sort keys %$controls) {
        my $c = $controls->{$uuid};
        next if ref($c) ne 'HASH' || gesperrt_typ($c->{type});
        if (defined $deadline && time() > $deadline) { $vollstaendig = 0; last; }
        my ($ok, $body) = $abruf->($uuid);
        if (!$ok) {
            $fehler++;
            if (++$consec >= AUSFALL_MAX) { $vollstaendig = 0; last; }
            next;
        }
        $consec = 0;
        my $aus = parse_all($body);
        next if !$aus;
        for my $a (@$aus) {
            push @eintraege, {
                b => $uuid, o => $a->[0],
                name => defined $c->{name} ? $c->{name} : '',
                raum => defined $c->{room} && defined $raum{ $c->{room} } ? $raum{ $c->{room} } : '',
                kat  => defined $c->{cat}  && defined $kat{ $c->{cat} }   ? $kat{ $c->{cat} }   : '',
                typ  => $c->{type}, einheit => $a->[2], wert => $a->[1], ts => $now,
            };
        }
    }
    return (\@eintraege, $vollstaendig, $fehler);
}

sub werte_lesen {
    my ($auswahl, $abruf, %opt) = @_;
    my $deadline = $opt{deadline};
    my %je;
    push @{ $je{ $_->{b} } }, $_->{o} for @$auswahl;
    my @bloecke = sort keys %je;
    my $anzahl  = scalar @bloecke;
    my $start   = ($anzahl && defined $opt{start}) ? ($opt{start} % $anzahl) : 0;
    my (@werte, $fehlt, $consec);
    my $vollstaendig = 1;
    $fehlt  = 0;
    $consec = 0;
    my $gelaufen = 0;
    for my $i (0 .. $anzahl - 1) {
        my $b = $bloecke[ ($start + $i) % $anzahl ];
        if (defined $deadline && time() > $deadline) { $vollstaendig = 0; last; }
        $gelaufen++;
        my ($ok, $body) = $abruf->($b);
        my $aus = $ok ? parse_all($body) : undef;
        if (!$aus) {
            $fehlt += scalar @{ $je{$b} };
            if (++$consec >= AUSFALL_MAX) { $vollstaendig = 0; last; }
            next;
        }
        $consec = 0;
        my %wert = map { $_->[0] => $_->[1] } @$aus;
        for my $o (@{ $je{$b} }) {
            if (exists $wert{$o}) { push @werte, { b => $b, o => $o, v => $wert{$o} }; }
            else                  { $fehlt++; }
        }
    }
    my $naechster = $anzahl ? (($start + $gelaufen) % $anzahl) : 0;
    return (\@werte, $fehlt, $vollstaendig, $naechster);
}

sub due {
    my ($state, $now) = @_;
    my $next = $state->{chart_next};
    return 1 if !defined $next;
    return 1 if $next > $now + INTERVALL * 5;
    return $next <= $now ? 1 : 0;
}

sub naechster {
    my ($now, $ok) = @_;
    return $now + ($ok ? INTERVALL : 60);
}

sub katalog_anforderung_faellig {
    my ($cs, $now, $anforderung) = @_;
    return 0 if !$anforderung;
    return 0 if $cs->{katalog_retry_at} && $cs->{katalog_retry_at} > $now;
    return 1;
}

sub version_pruefung_faellig {
    my ($cs, $now, $anforderung) = @_;
    return 0 if $cs->{katalog_retry_at} && $cs->{katalog_retry_at} > $now;
    return 1 if $anforderung;
    return 1 if !defined $cs->{katalog_version};
    return 1 if !defined $cs->{version_next} || $cs->{version_next} <= $now;
    return 0;
}

sub _auswahldatei { my ($dir) = @_; return File::Spec->catfile($dir, 'chart_auswahl.json'); }

sub auswahl_laden {
    my ($dir) = @_;
    my $f = _auswahldatei($dir);
    return [] if !-f $f;
    open my $fh, '<:raw', $f or return [];
    local $/;
    my $j = <$fh>;
    close $fh;
    my $d = eval { JSON::PP->new->utf8->decode($j) };
    return ref($d) eq 'ARRAY' ? $d : [];
}

sub auswahl_speichern {
    my ($dir, $liste) = @_;
    return 0 if ref($liste) ne 'ARRAY';
    my @sauber;
    for my $e (@$liste) {
        next if ref($e) ne 'HASH' || !defined $e->{msno} || $e->{msno} !~ /\A[0-9]+\z/
             || !defined $e->{b} || $e->{b} !~ /\A[0-9A-Za-z-]{1,64}\z/
             || !defined $e->{o} || $e->{o} !~ /\A[A-Za-z0-9_]{1,32}\z/;
        push @sauber, { msno => $e->{msno} + 0, b => $e->{b}, o => $e->{o} };
    }
    my $json = JSON::PP->new->canonical->utf8->encode(\@sauber);
    my $f = _auswahldatei($dir);
    if (-f $f && open(my $in, '<:raw', $f)) {
        local $/;
        my $alt = <$in>;
        close $in;
        return 1 if defined $alt && $alt eq $json;
    }
    my ($fh, $tmp) = tempfile('chart_auswahl.XXXXXX', DIR => $dir, UNLINK => 0);
    binmode $fh, ':raw';
    print {$fh} $json;
    close $fh or return 0;
    chmod 0600, $tmp;
    return move($tmp, $f) ? 1 : 0;
}

sub gruppen_der_auswahl {
    my ($liste) = @_;
    my %g;
    push @{ $g{ $_->{msno} } }, { b => $_->{b}, o => $_->{o} } for grep { ref($_) eq 'HASH' } @$liste;
    return \%g;
}

1;

