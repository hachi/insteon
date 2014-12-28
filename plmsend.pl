#!/usr/bin/perl

use strict;
use warnings;

use lib 'lib';

use Insteon::PLM;

my $plm = Insteon::PLM->new('/dev/ttyUSB0');

# Beep everything?
#$plm->send_all_link_command(9, '30');

# Write ALDB D2 0x02, D3-D4 address, D5 number of bytes (0x01-0x08), D6-D13 data to write.
# ALDB(0fbf) Group: 01 Address: nnnnnn(outside_drive) Control: 226 [In Use,Master,Next] 05 1c 01
#$plm->send_insteon_extended(qw(garage 2f00 00020FBF08000000000000000000));

# Request Product Data
#$plm->send_insteon_standard(qw(outside_garage 0300));
#$plm->send_insteon_standard(qw(front_light 0300));

# Request Device String
#$plm->send_insteon_standard(qw(garage 0302));

# Beep
#$plm->send_insteon_standard(qw(outside_garage 3001));

# Ping
#$plm->send_insteon_standard(qw(outside_garage 0F00));

# Extended settings get
#$plm->send_insteon_extended(qw(outside_garage 2E00 0000000000000000000000000000));
#$plm->send_insteon_extended(qw(front_light 2E00 0000000000000000000000000000));

# Extended settings set LED global LED brightness
#$plm->send_insteon_extended(qw(outside_garage 2E00 00077F0000000000000000000000));
#$plm->send_insteon_extended(qw(front_light 2E00 0007110000000000000000000000));

my $cb = sub {
    print @_;
};

#$plm->get_im_aldb($cb);

$plm->read_aldb($cb, shift);
$plm->loop();
