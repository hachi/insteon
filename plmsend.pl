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
#$plm->device('outside_garage')->get_product_data();
#$plm->device('front_light')->get_product_data();

# Request Device String
#$plm->device('garage')->get_device_string();

# Beep
#$plm->device('outside_garage')->beep();

# Ping
#$plm->device('outside_garage')->ping();

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

$plm->device(shift)->read_aldb($cb);
$plm->loop();
