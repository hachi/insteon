package Insteon::PLM;

use strict;
use warnings;

use Insteon::Device;
use Insteon::PLM::Serial;
use Insteon::Util qw(want_name get_name decode_aldb need_id);

sub LOOP_DEBUG () { 0 }
sub PACKET_DEBUG () { 0 }

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
	print STDERR "** INPUT [" . unpack("H*", $accumulator) . "] " . unpack("H*", $input) . "\n"
            if PACKET_DEBUG;
        $accumulator .= $input;
    };

    my $modem = Insteon::PLM::Serial->open($port);
    $modem->{on_read} = $on_read; # TODO accessor

    return bless {
        accumulator => \$accumulator,
        modem => $modem,
        command_queue => [],
        loop_ref_count => 0,
	blocked => 0,
    }, (ref $class || $class);
}

{
    sub Insteon::PLM::_LOOP_TOKEN::DESTROY {
        my $self = shift;
        my $plm = $$self;
        $plm->{loop_ref_count}--;
        LOOP_DEBUG && print STDERR "LOOP TOKEN -- $plm->{loop_ref_count}\n";
    }

    sub _loop_token {
        my $self = shift;
        $self->{loop_ref_count}++;
        LOOP_DEBUG && print STDERR "LOOP TOKEN ++ $self->{loop_ref_count}\n";
        return bless \$self, 'Insteon::PLM::_LOOP_TOKEN';
    }

    sub _loop_refs {
        my $self = shift;
        LOOP_DEBUG && print STDERR "LOOP REF COUNT $self->{loop_ref_count}\n";
        return $self->{loop_ref_count};
    }
}

sub loop {
    my $self = shift;

    while ($self->_loop_refs()) {
        next if $self->loop_one();
    }
}

sub loop_one {
    my $self = shift;

    my $accumulator = $self->{accumulator};
    my $command_queue = $self->{command_queue};

    $self->flush_commands();
    Insteon::PLM::Serial->poll();

    while (length($$accumulator) >= 1) {
	if (substr($$accumulator, 0, 1) eq "\x06") {
	    print STDERR "Peeling off a spurious ACK\n";
	    substr($$accumulator, 0, 1, '');
	    next;
	}
        # If we get a NAK that means the IM wasn't ready for the next one. Replay.
        if (substr($$accumulator, 0, 1) eq "\x15") {
            substr($$accumulator, 0, 1, '');
            print STDERR "DOES THIS EVER FIRE? Sending command again\n";
	    $self->{blocked} = 0;
	    $self->flush_commands();
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
            } elsif ($cmd eq "\x53") {
                $self->all_linking_completed($data);
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

            my $command_entry = shift @$command_queue;
	    $self->{blocked} = 0;
            my $estatement = $command_entry->[0];
            my $callback = $command_entry->[1];

            my $statement = substr($$accumulator, 0, $elen - 1);

            print STDERR "Expecting : " . unpack("H*", $estatement) . "\n"
                if PACKET_DEBUG;
            print STDERR "Got       : " . unpack("H*", $statement) . "\n"
                if PACKET_DEBUG;
            die("Mismatched statement") unless $estatement eq $statement;

            my $input = substr($$accumulator, $elen - 1, 1);
            if ($input eq "\x06") {
                $callback->(ACK);
            } elsif ($input eq "\x15") {
                $callback->(NAK);
            } else {
		warn "Accumulator contains: " . unpack("H*", $$accumulator);
                die "Unknown result: " . unpack("H*", $input);
            }

            substr($$accumulator, 0, $elen, '');
            next;
        }
        if ($cmd eq "\x60") { # Get IM Information
            return 1 unless $len >= 9;

            my $command_entry = shift @$command_queue;
	    $self->{blocked} = 0;
            my $estatement = $command_entry->[0];
            my $callback = $command_entry->[1];

            # For this command we only compare two bytes to the command queue
            my $statement = substr($$accumulator, 0, 2);

            print STDERR "Expecting : " . unpack("H*", $estatement) . "\n"
                if PACKET_DEBUG;
            print STDERR "Got       : " . unpack("H*", $statement) . "\n"
                if PACKET_DEBUG;
            die("Mismatched statement: ") unless $estatement eq $statement;

            my $input = substr($$accumulator, 2, 6);
            my $status = substr($$accumulator, 8, 1);
            my ($address, $category, $subcategory, $firmware) = unpack('H[6]CCC', $input);
            if ($status eq "\x06") {
                $callback->(ACK, $address, $category, $subcategory, $firmware);
            } elsif ($status eq "\x15") {
                $callback->(NAK);
            } else {
                die "Unknown result";
            }

            substr($$accumulator, 0, 9, '');
            next;
        } elsif ($cmd eq "\x62") { # Send Insteon Standard/Extended
            return 1 unless $len >= 9;

            my $flags = substr($$accumulator, 5, 1);
            print STDERR "Flags are : " . unpack("H*", $flags) . "\n"
                if PACKET_DEBUG;
            my $elen = (ord($flags) & 16) ? 23 : 9;

            return 1 unless $len >= $elen;

            my $command_entry = shift @$command_queue;
	    $self->{blocked} = 0;
            my $estatement = $command_entry->[0];
            my $callback = $command_entry->[1];

            my $statement = substr($$accumulator, 0, $elen - 1);

            print STDERR "Expecting : " . unpack("H*", $estatement) . "\n"
                if PACKET_DEBUG;
            print STDERR "Got       : " . unpack("H*", $statement) . "\n"
                if PACKET_DEBUG;
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
        } elsif ($cmd eq "\x6B") { # Set IM Configuration
            return 1 unless $len >= 4;

            my $command_entry = shift @$command_queue;
	    $self->{blocked} = 0;
            my $estatement = $command_entry->[0];
            my $callback = $command_entry->[1];

            # For this command we only compare three bytes to the command queue
            my $statement = substr($$accumulator, 0, 3);

            print STDERR "Expecting : " . unpack("H*", $estatement) . "\n"
                if PACKET_DEBUG;
            print STDERR "Got       : " . unpack("H*", $statement) . "\n"
                if PACKET_DEBUG;
            die("Mismatched statement: ") unless $estatement eq $statement;

            my $flags = substr($$accumulator, 2, 1);
            my $input = substr($$accumulator, 3, 1);
            if ($input eq "\x06") {
                $callback->(ACK);
            } elsif ($input eq "\x15") {
                $callback->(NAK);
            } else {
                die "Unknown result";
            }

            substr($$accumulator, 0, 4, '');
            next;
        } elsif ($cmd eq "\x73") { # Get IM Configuration
            return 1 unless $len >= 6;

            my $command_entry = shift @$command_queue;
	    $self->{blocked} = 0;
            my $estatement = $command_entry->[0];
            my $callback = $command_entry->[1];

            # For this command we only compare two bytes to the command queue
            my $statement = substr($$accumulator, 0, 2);

            print STDERR "Expecting : " . unpack("H*", $estatement) . "\n"
                if PACKET_DEBUG;
            print STDERR "Got       : " . unpack("H*", $statement) . "\n"
                if PACKET_DEBUG;
            die("Mismatched statement: ") unless $estatement eq $statement;

            my $flags = substr($$accumulator, 2, 1);
            my $input = substr($$accumulator, 5, 1);
            if ($input eq "\x06") {
                $callback->(ACK, $flags);
            } elsif ($input eq "\x15") {
                $callback->(NAK);
            } else {
                die "Unknown result";
            }

            substr($$accumulator, 0, 6, '');
            next;
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
        broadcast => 0,
        group => 0,
    );

    my %opts = (%defaults, @_);
    return 0 +
        ($opts{broadcast} ? 128 : 0) +
        ($opts{group} ? 64 : 0) +
        ($opts{extended} ? 16 : 0) +
        ($opts{max_hops} & 3);
};

sub plm_command {
    my $self = shift;
    my $output = shift;
    my $callback = shift;

    my $command_queue = $self->{command_queue};

    push @$command_queue, [ $output, $callback, $self->_loop_token() ];
    $self->flush_commands();
}

sub flush_commands {
    my $self = shift;
    my $command_queue = $self->{command_queue};
    my $modem = $self->{modem};

    return if $self->{blocked};

    return unless @$command_queue;
    my $next_command = $command_queue->[0];
    my $output = $next_command->[0];
    print STDERR "** OUTPUT: " . unpack("H*", $output) . "\n"
        if PACKET_DEBUG;
    $modem->send($output);
    $self->{blocked}++;
}

sub get_im_info {
    my $self = shift;
    my $callback = shift;
    my $output = "\x02\x60";

    $self->plm_command($output, $callback);
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
    $output .= pack("H[6]CH[4]", need_id($device), $flags->(), $command);

    $self->plm_command($output, $callback);
}

sub send_insteon_extended {
    my $self = shift;
    my ($device, $command, $data, $callback) = @_;
    my $output = "\x02\x62";
    $output .= pack("H[6]CH[4]H[28]", need_id($device), $flags->(extended => 1), $command, $data);

    $self->plm_command($output, $callback);
}

sub send_insteon_group {
    my $self = shift;
    my ($group, $command, $callback) = @_;
    my $output = "\x02\x62";
    $output .= pack("H[4]CCH[4]", "0000", $group, $flags->(group => 1, broadcast => 1), $command);

    $self->plm_command($output, $callback);
}

# 0x63, send X10 command

my $im_linking_listener;
my $im_linking_lock = 0;

sub start_all_linking {
    my $self = shift;
    my ($command, $group, $callback) = @_;

    die if $im_linking_lock;
    $im_linking_lock = $self->_loop_token();

    my $output = "\x02\x64";
    $output .= pack("CC", $command, $group);

    $self->plm_command($output, sub {
         $im_linking_listener = $callback;
    });
}

sub cancel_all_linking {
    my $self = shift;
    my ($callback) = @_;
    my $output = "\x02\x65";

    $self->plm_command($output, $callback);
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

my $im_aldb_listener;
my $im_aldb_lock = 0;

sub get_im_aldb {
    my $self = shift;
    my $callback = shift;

    die if $im_aldb_lock;
    $im_aldb_lock = $self->_loop_token();

    my $next;

    my $aldb = Insteon::Util::ALDBList->new();

    $im_aldb_listener = sub {
        push @$aldb, @_;
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
            $callback->($aldb);
            return;
        }
        die;
    };

    $self->_first_all_link_record($next);
}

sub set_im_config {
    my $self = shift;
    my %conf = @_;

    my $flags = 0;

    $flags |= (2**7) if $conf{disable_auto_linking};
    $flags |= (2**6) if $conf{monitor_mode};
    $flags |= (2**5) if $conf{disable_auto_led};
    $flags |= (2**4) if $conf{disable_deadman_timeout};

    my $output = "\x02\x6B" . pack("C", $flags);

    my $cb = sub {
        my $status = shift;
        die "NAK?" unless $status == ACK;
        my $rawflags = shift;
        my $flags = unpack("C", $rawflags);
        my @decoded;
        push @decoded, '(7) Disabled automatic linking' if $flags & (2**7);
        push @decoded, '(6) Monitor mode'               if $flags & (2**6);
        push @decoded, '(5) Disabled automatic LED'     if $flags & (2**5);
        push @decoded, '(4) Disabled deadman timeout'   if $flags & (2**4);
        print STDERR "Flags        : " . unpack("H*", $rawflags) . "\n";
        print STDERR "Decoded Flags: " . join(', ', @decoded) . "\n";
    };

    $self->plm_command($output, $cb);
}

sub get_im_config {
    my $self = shift;
    my $output = "\x02\x73";

    my $cb = sub {
        my $status = shift;
        die "NAK?" unless $status == ACK;
        my $rawflags = shift;
        my $flags = unpack("C", $rawflags);
        my @decoded;
        push @decoded, '(7) Disabled automatic linking' if $flags & (2**7);
        push @decoded, '(6) Monitor mode'               if $flags & (2**6);
        push @decoded, '(5) Disabled automatic LED'     if $flags & (2**5);
        push @decoded, '(4) Disabled deadman timeout'   if $flags & (2**4);
        print STDERR "Flags        : " . unpack("H*", $rawflags) . "\n";
        print STDERR "Decoded Flags: " . join(', ', @decoded) . "\n";
    };

    $self->plm_command($output, $cb);
}

sub device {
    my $self = shift;
    my $address = need_id(shift);

    return Insteon::Device->get($self, $address);
}

sub MSG_DIRECT         { (shift() & 0b11100000) == 0b00000000 }
sub MSG_DIRECT_ACK     { (shift() & 0b11100000) == 0b00100000 }
sub MSG_DIRECT_NAK     { (shift() & 0b11100000) == 0b10100000 }
sub MSG_BROADCAST      { (shift() & 0b11100000) == 0b10000000 }
sub MSG_AL_BROADCAST   { (shift() & 0b11100000) == 0b11000000 }
sub MSG_AL_CLEANUP     { (shift() & 0b11100000) == 0b01000000 }
sub MSG_AL_CLEANUP_ACK { (shift() & 0b11100000) == 0b01100000 }
sub MSG_AL_CLEANUP_NAK { (shift() & 0b11100000) == 0b11100000 }
sub MSG_STANDARD       { (shift() & 0b00010000) == 0b00000000 }
sub MSG_EXTENDED       { (shift() & 0b00010000) == 0b00010000 }

sub debug_message {
    my ($from, $to, $flag, $command, $data) = @_;

    foreach my $addr ($from, $to) {
        if (my $name = get_name($addr)) {
            $addr .= "($name)";
        }
    }

    my ($hexdata) = defined($data) ? unpack('H[28]', $data) : '';

    my $extra = '';

    $extra .= "Standard"                            if MSG_STANDARD($flag);
    $extra .= "Extended"                            if MSG_EXTENDED($flag);

    $extra .= " Direct message"                     if MSG_DIRECT($flag);
    $extra .= " ACK Direct message"                 if MSG_DIRECT_ACK($flag);
    $extra .= " NAK Direct message"                 if MSG_DIRECT_NAK($flag);
    $extra .= " Broadcast message"                  if MSG_BROADCAST($flag);
    $extra .= " ALL-Link Broadcast Message"         if MSG_AL_BROADCAST($flag);
    $extra .= " ALL-Link Cleanup Message"           if MSG_AL_CLEANUP($flag);
    $extra .= " ALL-Link Cleanup ACK Message"       if MSG_AL_CLEANUP_ACK($flag);
    $extra .= " ALL-Link Cleanup NAK Message"       if MSG_AL_CLEANUP_NAK($flag);

    my $hops_left = ($flag & 0b00001100) >> 2;
    my $hops_max  = ($flag & 0b00000011);
    $extra .= " hops($hops_left/$hops_max)";

    print "[$from -> $to] $command $hexdata $extra\n";
    return;
}

sub decode_standard {
    my $self = shift;

    my $input = shift;

    my ($from, $to, $flag, $command) = unpack('H[6]H[6]CH[4]', $input);

    PACKET_DEBUG && debug_message($from, $to, $flag, $command);

    return $self->device($from)->_receive($from, $to, $flag, $command);
}

sub decode_extended {
    my $self = shift;

    my $input = shift;

    my ($from, $to, $flag, $command, $data) = unpack('H[6]H[6]CH[4]a[14]', $input);

    PACKET_DEBUG && debug_message($from, $to, $flag, $command, $data);

    return $self->device($from)->_receive($from, $to, $flag, $command, $data);
}

sub decode_all_link_record {
    my $self = shift;

    my $record = shift;

    $im_aldb_listener->(decode_aldb($record));

    return 1;
}

sub all_linking_completed {
    my $self = shift;

    my $input = shift;

    my ($code, $group, $address, $category, $subcategory, $firmware) = unpack('CCH[6]CCC', $input);

    $im_linking_listener->("All linking completed: code=$code group=$group address=$address category=$category subcategory=$subcategory firmware=$firmware");
    $im_linking_lock = 0;

    return 1;
}

1;
