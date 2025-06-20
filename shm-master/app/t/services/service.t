use strict;
use warnings;

use Test::More;

use Data::Dumper;
use v5.14;

$ENV{SHM_TEST} = 1;

use SHM;
SHM->new( user_id => 40092 );

use Core::System::ServiceManager qw( get_service );

my $service = get_service('service', _id => 1);
$service->set( cost => 5 );

my $si = get_service('service', _id => 1)->get;
is ( $si->{service_id}, 1 );
is ( $si->{cost}, 5 );
is ( $service->get_cost, 5 );

$si = get_service('service', _id => 2)->get;

is ( $si->{service_id}, 2 );
is ( $si->{cost}, 100 );

$si = $service->add( name => 'TEST', cost => 123, category => 'new' )->get;
is ( $si->{name}, 'TEST', 'Check create new service' );

is_deeply( scalar $service->categories, [
    'web_tariff_lock',
    'web_tariff',
    'web',
    'mail',
    'domain',
    'domain_prolong',
    'mysql',
    'dns',
    'domain_add',
    'transfer',
    'new',
], 'Check categories() function');

done_testing();
