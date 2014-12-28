package Insteon::PLM;

use strict;
use warnings;

use Insteon::PLM::Serial;
use Insteon::Util qw(want_name want_id get_name);

sub DEBUG () { 0 }

sub ACK () { 0x06 }
sub NAK () { 0x15 }

sub new {
    my $class = shift;
    my $port = shift;

    my $accumulator = "";

    my $on_read = sub {
        my ($modem, $input, $inlen) = @_;
        # The accumulator is a buffer that keeps the incoming stream left aligned for
        # parsing. If there is a failure in parsing we're going to cycle the serial
        # port to attempt to realign.
        $accumulator .= $input;
    };

    my $modem = Insteon::PLM::Serial->open($port);
    $modem->{on_read} = $on_read; # TODO accessor

    return bless {
        accumulator => \$accumulator,
        modem => $modem,
    }, (ref $class || $class);
}

my $im_aldb_listener;
my %get_aldb_device_listener;
my @command_queue;

sub loop {
    my $self = shift;

    {
        redo if $self->loop_one();
    }
}

sub loop_one {
    my $self = shift;

    my $accumulator = $self->{accumulator};

    if ($im_aldb_listener) {
        DEBUG && print STDERR "Continuing because of im_aldb_listener\n";
    } elsif (@command_queue) {
        DEBUG && print STDERR "Continuing because of command_queue\n";
    } elsif (keys %get_aldb_device_listener) {
        DEBUG && print STDERR "Continuing because of get_aldb_device_listener\n";
    } else {
        return 0;
    }

    Insteon::PLM::Serial->poll();

    while (length($$accumulator) >= 1) {
        # If we get a NAK that means the IM wasn't ready for the next one. Replay.
        if (substr($$accumulator, 0, 1) eq "\x15") {
            substr($$accumulator, 0, 1, '');
            my $command_entry = shift @command_queue;
            my $estatement = $command_entry->[0];
            print STDERR "Sending command again: " . unpack("H*", $estatement) . "\n";
            $self->{modem}->send($estatement);
            push @command_queue, $command_entry;
            next;
        }
        # STX Is the valid mark of any input record
        unless (substr($$accumulator, 0, 1) eq "\x02") {
            print STDERR "Unsyncronized Read: " . unpack("H*", $$accumulator) . "\n";
            die;
        }

        my $len = length($$accumulator);

        # Command byte
        return 1 unless $len >= 2;
        my $cmd = substr($$accumulator, 1, 1);
        my %cmd_inp_len = (
            ## Informational frames
            "\x50" => 11,       # Receive Standard
            "\x51" => 25,       # Receive Extended
            "\x52" => 4,        # Receive X10
            "\x53" => 10,       # All-Linking Completed
            "\x54" => 3,        # Button Event Report
            "\x55" => 2,        # User Reset Detected
            "\x56" => 7,        # All-Link Cleanup Failure Report
            "\x57" => 10,       # All-Link Record Response
            "\x58" => 3,        # All-Link Cleanup Status Report
        );

        if (my $elen = $cmd_inp_len{$cmd}) {
            return 1 unless $len >= $elen;

            my $data = substr($$accumulator, 2, $elen - 2);
            if ($cmd eq "\x50") {
                $self->decode_standard($data);
            } elsif ($cmd eq "\x51") {
                $self->decode_extended($data);
            } elsif ($cmd eq "\x57") {
                $self->decode_all_link_record($data);
            } elsif ($cmd eq "\x58") {
                die("NAK") if $data eq "\x15";
                die("!ACK") if $data ne "\x06";
                print "All-Link Command Successful\n";
            } else {
                print STDERR "Command: " . unpack("H*", $cmd) . "\n";
                print STDERR "Data:    " . unpack("H*", $data) . "\n";
                die "Not sure what to do here.\n";
            }
            substr($$accumulator, 0, $elen, '');
            next;
        }

        # Incoming ACK/NAK for commands issued.
        my %cmd_ack_len = (
            ## Issued command ACK/NAK replies
            # Typically these are replied to with a single ACK/NAK frame
            # to indicate action success.
            # (X)       responses will arrive via information frames so
            #           we will need to maintain some state for tracking
          # "\x60" => 9,        # Get IM Info (Special)
            "\x61" => 6,        # Send All-Link Command (X)
          # "\x62" => 9 or 23   # Send Standard/Extended (Special)
            "\x63" => 5,        # Send X10
            "\x64" => 5,        # Start All-Linking (X)
            "\x65" => 3,        # Cancel All-Linking
            "\x66" => 6,        # Set Device Category
            "\x67" => 3,        # Reset IM
            "\x68" => 4,        # Set ACK One Byte
            "\x69" => 3,        # Get First All-Link Record (X)
            "\x6A" => 3,        # Get Next All-Link Record (X)
            "\x6B" => 4,        # Set IM Configuration
            "\x6C" => 3,        # Get All-Link Record For Sender (X)
            "\x6D" => 3,        # LED On
            "\x6E" => 3,        # LED Off
            "\x6F" => 12,       # Manage All-Link Record
            "\x70" => 4,        # Set NAK One Byte
            "\x71" => 5,        # Set ACK Two Bytes
            "\x72" => 3,        # RF Sleep
          # "\x73" => 6,        # Get IM Configuration (Special)
        );

        if (my $elen = $cmd_ack_len{$cmd}) {
            return 1 unless $len >= $elen;

            my $command_entry = shift @command_queue;
            my $estatement = $command_entry->[0];
            my $callback = $command_entry->[1];

            my $statement = substr($$accumulator, 0, $elen - 1);

            print STDERR "Expecting : " . unpack("H*", $estatement) . "\n"
                if DEBUG;
            print STDERR "Got       : " . unpack("H*", $statement) . "\n"
                if DEBUG;
            die("Mismatched statement") unless $estatement eq $statement;

            my $input = substr($$accumulator, $elen - 1, 1);
            if ($input eq "\x06") {
                $callback->(ACK);
            } elsif ($input eq "\x15") {
                $callback->(NAK);
            } else {
                die "Unknown result";
            }

            substr($$accumulator, 0, $elen, '');
            next;
        }
        if ($cmd eq "\x60") { # Get IM Information
            die;
        } elsif ($cmd eq "\x62") { # Send Insteon Standard/Extended
            return 1 unless $len >= 9;

            my $flags = substr($$accumulator, 5, 1);
            print STDERR "Flags are : " . unpack("H*", $flags) . "\n"
                if DEBUG;
            my $elen = (ord($flags) & 16) ? 23 : 9;

            return 1 unless $len >= $elen;

            my $command_entry = shift @command_queue;
            my $estatement = $command_entry->[0];
            my $callback = $command_entry->[1];

            my $statement = substr($$accumulator, 0, $elen - 1);

            print STDERR "Expecting : " . unpack("H*", $estatement) . "\n"
                if DEBUG;
            print STDERR "Got       : " . unpack("H*", $statement) . "\n"
                if DEBUG;
            die("Mismatched statement: ") unless $estatement eq $statement;

            my $input = substr($$accumulator, $elen - 1, 1);
            if ($input eq "\x06") {
                $callback->(ACK);
            } elsif ($input eq "\x15") {
                $callback->(NAK);
            } else {
                die "Unknown result";
            }

            substr($$accumulator, 0, $elen, '');
            next;
        } elsif ($cmd eq "\x73") { # Get IM Configuration
            die;
        }
        die "Completely unknown/unexpected command";
    }

    return 1;
}

my $flags = sub {
    my %defaults = (
        extended => 0,
        max_hops => 3,
        rem_hops => 3,
    );

    my %opts = (%defaults, @_);
    return 0 + ($opts{extended} ? 16 : 0) + ($opts{max_hops} & 3);
};

sub plm_command {
    my $self = shift;
    my $output = shift;
    my $callback = shift;

    print STDERR "Sending: " . unpack("H*", $output) . "\n"
        if DEBUG;
    my $modem = $self->{modem};
    $modem->send($output);

    push @command_queue, [ $output, $callback ];
}

sub get_im_info {
    my $self = shift;
    my $output = "\x02\x60";

    $self->plm_command($output);
}

sub send_all_link_command {
    my $self = shift;
    my ($group, $command) = @_;
    my $output = "\x02\x61";
    $output .= pack("CH[4]", $group, $command);

    $self->plm_command($output);
}

sub send_insteon_standard {
    my $self = shift;
    my ($device, $command, $callback) = @_;
    my $output = "\x02\x62";
    $output .= pack("H[6]CH[4]", want_id($device), $flags->(), $command);

    $self->plm_command($output, $callback);
}

sub send_insteon_extended {
    my $self = shift;
    my ($device, $command, $data, $callback) = @_;
    my $output = "\x02\x62";
    $output .= pack("H[6]CH[4]H[28]", want_id($device), $flags->(extended => 1), $command, $data);

    $self->plm_command($output, $callback);
}

# 0x63, send X10 command

sub start_all_linking {
    my $self = shift;
    my $output = "\x02\x64";

    $self->plm_command($output);
}

sub cancel_all_linking {
    my $self = shift;
    my $output = "\x02\x65";

    $self->plm_command($output);
}

# 0x65, set host device category

sub factory_reset_im {
    my $self = shift;
    my $output = "\x02\x67";

    $self->plm_command($output);
}

sub _first_all_link_record {
    my $self = shift;
    my $output = "\x02\x69";

    $self->plm_command($output, @_);
}

sub _next_all_link_record {
    my $self = shift;
    my $output = "\x02\x6A";

    $self->plm_command($output, @_);
}

my $im_aldb_lock = 0;

sub get_im_aldb {
    my $self = shift;
    my $callback = shift;

    die if $im_aldb_lock;
    $im_aldb_lock = 1;
    my @records;

    my $next;

    $im_aldb_listener = sub {
        push @records, @_;
        $self->_next_all_link_record($next);
    };

    $next = sub {
        my $i = shift;
        if ($i == ACK) {
            return;
        }
        if ($i == NAK) {
            $im_aldb_lock = 0;
            $im_aldb_listener = undef;
            $callback->(@records);
            return;
        }
        die;
    };

    $self->_first_all_link_record($next);
}

my %aldb_lock_device = ();

sub read_aldb {
    my $self = shift;
    my $callback = shift;
    my $device = shift;
    my $device_id = want_id($device);

    die if $aldb_lock_device{$device_id};
    $aldb_lock_device{$device_id} = 1;

    my @records;

    my $listener = sub {
        push @records, @_;
        unless ($records[-1] =~ m/\bNext\b/) {
            $aldb_lock_device{$device_id} = 0;
            delete $get_aldb_device_listener{$device_id};
            $callback->(@records);
            return;
        }
        # Advance timeout if we have one
    };

    $self->send_insteon_extended($device, qw(2f00 0000000000000000000000000000), sub {
        $get_aldb_device_listener{$device_id} = $listener;
    });
}

sub decode_standard {
    my $self = shift;

    my $input = shift;

    my ($from, $to, $flag, $command) = unpack('H[6]H[6]CH[4]', $input);

    foreach my $addr ($from, $to) {
        if (my $name = get_name($addr)) {
            $addr .= "($name)";
        }
    }

    my $extra = '';
    $extra .= " Direct message"             if (($flag & 0xE0) == 0);
    $extra .= " ACK Direct message"         if (($flag & 0xE0) == 0x20);
    $extra .= " NAK Direct message"         if (($flag & 0xE0) == 0xA0);
    $extra .= " Broadcast message"          if (($flag & 0xE0) == 0x80);
    $extra .= " ALL-Link Broadcast Message" if (($flag & 0xE0) == 0xC0);
    $extra .= " ALL-Link Broadcast Message" if (($flag & 0xE0) == 0x40);
    $extra .= " ACK ALL-Link Message"       if (($flag & 0xE0) == 0x60);
    $extra .= " NAK ALL-Link Message"       if (($flag & 0xE0) == 0xE0);

    DEBUG && print "[$from -> $to] $command$extra\n";
    return 1;
}

sub decode_extended {
    my $self = shift;

    my $input = shift;

    my ($from, $to, $flag, $command, $data) = unpack('H[6]H[6]CH[4]a[14]', $input);
    my $raw_from = $from;

    foreach my $addr ($from, $to) {
        if (my $name = get_name($addr)) {
            $addr .= "($name)";
        }
    }

    my ($hexdata) = unpack('H[28]', $data);

    my $extra = '';
    $extra .= " Direct message"             if (($flag & 0xE0) == 0);
    $extra .= " ACK Direct message"         if (($flag & 0xE0) == 0x20);
    $extra .= " NAK Direct message"         if (($flag & 0xE0) == 0xA0);
    $extra .= " Broadcast message"          if (($flag & 0xE0) == 0x80);
    $extra .= " ALL-Link Broadcast Message" if (($flag & 0xE0) == 0xC0);
    $extra .= " ALL-Link Broadcast Message" if (($flag & 0xE0) == 0x40);
    $extra .= " ACK ALL-Link Message"       if (($flag & 0xE0) == 0x60);
    $extra .= " NAK ALL-Link Message"       if (($flag & 0xE0) == 0xE0);

    DEBUG && print "[$from -> $to] $command $hexdata$extra\n";

    if ($command eq '0300') {
        # Product Data Response
        # D1: 0x00, D2-D4: Product Key, D5: DevCat, D6: SubCat, D7: Firmware, D8-D14: unspec
        my ($prod_key, $dev_cat, $sub_cat, $firmware) = unpack('xH[6]H[2]H[2]H[2]', $data);
        print "Product Data PK: $prod_key Category: $dev_cat/$sub_cat Firmware: $firmware\n";
    }

    if ($command eq '2e00') {
        my ($bg, $verb, $x10h, $x10u) = unpack('H[2]H[2]xxH[2]H[2]', $data);
    }

    if ($command eq '2f00') {
        # All Link DB
        my ($rrw, $address, $l, $record) = unpack('xCH[4]Ca[8]x', $data);
        if ($rrw == 1) {
            my $record = "ALDB($address) " . decode_aldb($record) . "\n";
            if (my $listener = $get_aldb_device_listener{$raw_from}) {
                $listener->($record);
            } else {
                print $record;
            }
        }
    }

    return 1;
}

sub decode_all_link_record {
    my $self = shift;

    my $record = shift;

    $im_aldb_listener->("ALDB(n) " . decode_aldb($record) . "\n");

    return 1;
}

sub decode_aldb {
    my $input = shift;

    die "Wrong DB entry length" unless length($input) == 8;

    my @output;

    my ($control, $group, $address, $d1, $d2, $d3) = unpack('CH[2]H[6]H[2]H[2]H[2]', $input);

    if ($control & 128) {
        push @output, "In Use";
    }

    push @output, ($control & 64) ? "Master" : "Slave";

    if ($control & 2) {
        push @output, "Next";
    }

    if (my $name = get_name($address)) {
        $address .= "($name)";
    }

    return "Group: $group Address: $address Control: " . $control . " [" . join(',', @output) . "] $d1 $d2 $d3";
}

1;