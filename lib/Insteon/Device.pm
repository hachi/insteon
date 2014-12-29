package Insteon::Device;

use strict;
use warnings;

use Scalar::Util qw(weaken);

our %devices;

sub get {
    my $class = shift;
    my $plm = shift;
    my $address = shift;

    return $devices{$address} if $devices{$address};

    my $self = bless {
        address => $address,
        plm     => $plm,
    }, (ref $class || $class);

    weaken($devices{$address} = $self);

    return $self;
}

sub read_aldb {
    my $self = shift;
    my $callback = shift;

    die if $self->{aldb_lock};
    $self->{aldb_lock} = $self->{plm}->_loop_token();

    my @records;

    my $listener = sub {
        push @records, @_;
        unless ($records[-1] =~ m/\bNext\b/) {
            delete $self->{aldb_lock};
            delete $self->{aldb_listener};
            $callback->(@records);
            return;
        }
        # Advance timeout if we have one
    };

    $self->{plm}->send_insteon_extended($self->{address}, qw(2f00 0000000000000000000000000000), sub {
        $self->{aldb_listener} = $listener;
    });
}

sub _receive_aldb {
    my $self = shift;
    my $record = shift;
    if (my $listener = $self->{aldb_listener}) {
        $listener->($record);
    } else {
        print "Unsolicited ALDB record: " . $record;
    }
}

1;
