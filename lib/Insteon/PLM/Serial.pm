package Insteon::PLM::Serial;

use strict;
use warnings;

use IO::Termios;
use Scalar::Util qw(weaken);
use Errno qw(EAGAIN);

sub DEBUG () { 0 }

my @PLMrefs;

sub DESTROY {
    my $self = shift;
    DEBUG && print STDERR "${self}\->DESTROY() during ${^GLOBAL_PHASE} called.\n";
    return
}

sub open {
    my $package = shift;
    my $device = shift;
    my $term = IO::Termios->open($device, "19200,8,n,1")
        or die "Cannot open $device - $!";

    $term->blocking(0);

    my $plm = bless {
        dev => $term,
        write_buf => [],
        on_read => undef,
    }, (ref($package) || $package);

    # We have to weaken a blessed ref, but can't take a copy of it.
    # So take a ref and then deref it to weaken. Ew.
    my $plm_copy = $plm;
    my $plmref = \$plm;
    weaken($$plmref);
    push @PLMrefs, $plmref;

    return $plm_copy;
}

sub poll {
    my $self = shift; # Might be called as a package method though too.

    my ($rin, $win) = ('', '');
    my %FilenoToPLM;

    {
        my @PLMs = ref $self ? ($self) : (map { $$_ } grep { $$_ } @PLMrefs);

        foreach my $plm (@PLMs) {
            my $term = $plm->{dev};
            my $fileno = fileno($term);
            if ($plm->{on_read}) {
                DEBUG && print STDERR "Watching for readability on $plm\n";
                vec($rin, $fileno,  1) = 1;
            }
            if (@{$plm->{write_buf}}) {
                DEBUG && print STDERR "Watching for writability on $plm\n";
                vec($win, $fileno,  1) = 1
            }
            $FilenoToPLM{$fileno} = $plm;
        }
    }

    my $timeout = 5;

    my ($nfound, $timeleft) =
        select(my $rout=$rin, my $wout=$win, undef, $timeout);

    unless($nfound) {
        warn "No ready handles found\n";
        return;
    }

    foreach my $fileno (keys %FilenoToPLM) {
        my $plm = $FilenoToPLM{$fileno};
        if (vec($rout, $fileno,  1)) {
            DEBUG && print STDERR "Got readability on $plm\n";
            $plm->readable();
        }
        if (vec($wout, $fileno,  1)) {
            DEBUG && print STDERR "Got writability on $plm\n";
            $plm->writable();
        }
    }
}

sub readable {
    my $self = shift;
    my $term = $self->{dev};

    DEBUG && print STDERR "Reading from $self\n";
    my $inlen = $term->sysread(my $input, 1024);
    unless (defined $inlen) {
        return 0 if $! == EAGAIN;
        DEBUG && print STDERR "Failed (undef) read from $self: $!\n";
        return 1;
    }
    unless ($inlen > 0) {
        DEBUG && print STDERR "Failed (negative) read from $self: $!\n";
        return 1;
    }
    print STDERR "Read $inlen bytes: " . unpack("H*", $input) . "\n"
        if DEBUG;
    $self->{on_read}->($self, $input, $inlen);
}

sub writable {
    my $self = shift;
    my $term = $self->{dev};

    my $write_buf = $self->{write_buf};

    while (@$write_buf) {
        DEBUG && print STDERR "Running one write pass\n";

        my $cur = $write_buf->[0];
        if (ref($cur) eq 'CODE') {
            shift @$write_buf;
            print STDERR "Calling write callback: $cur\n";
            $cur->($self);
            next;
        }

        my $len = length($cur);
        my $rv = $self->{dev}->syswrite($cur);

        unless (defined($rv) && $rv > 0) {
            return if $! == EAGAIN;
            die "Failed to write: $!"
        }
        return if $rv == 0;

        if ($rv == $len) {
            my $sent = shift @$write_buf;
            print STDERR "Flushed full buffer $rv bytes: " . unpack("H*", $sent) . "\n"
                if DEBUG;
            next;
        }

        my $sent = substr($write_buf->[0], 0, $rv, '');
        print STDERR "Flushed $rv bytes: " . unpack("H*", $sent) . "\n"
            if DEBUG;
        return;
    }
}

sub send {
    my $self = shift;
    push @{$self->{write_buf}}, @_;
}

1;
