use v5.14;

use Test::More;
use Test::MockTime;
use Test::Deep;
use Core::Billing;
use POSIX qw(tzset);

$ENV{SHM_TEST} = 1;

use Core::System::ServiceManager qw( get_service );
use Core::Utils qw(now);
use SHM;
my $user = SHM->new( user_id => 40092 );

$ENV{TZ} = 'Europe/London'; #UTC+0
tzset;

subtest 'Moneyback' => sub {
    my $service = get_service('service')->add(
        name => 'test service',
        cost => '900',
        category => 'test',
        no_discount => 1,
    );

    Test::MockTime::set_fixed_time('2019-04-01T00:00:00Z');

    my $start_balance = $user->get->{balance};
    is ( $start_balance, -21.56, 'Check start balance');

    my $us = create_service( service_id => $service->id );

    my $wd = $us->withdraw;
    cmp_deeply( scalar $wd->get,
        {
              'bonus' => '0',
              'months' => 1,
              'create_date' => '2019-04-01 01:00:00',
              'withdraw_date' => '2019-04-01 01:00:00',
              'user_id' => 40092,
              'user_service_id' => $us->id,
              'qnt' => 1,
              'total' => 900,
              'end_date' => '2019-05-01 01:01:59',
              'cost' => '900',
              'service_id' => $service->id,
              'withdraw_id' => $wd->id,
              'discount' => 0
          }
    , 'Check withdraw');

    my $balance_after_create = $user->get->{balance};
    is ( $balance_after_create, -921.56, 'Check balance after create');

    Test::MockTime::set_fixed_time('2019-04-03T00:00:00Z');
    $us->set( expire => now );

    money_back( $us );

    cmp_deeply( scalar $wd->get,
        {
              'bonus' => '0',
              'months' => '0.02',
              'create_date' => '2019-04-01 01:00:00',
              'withdraw_date' => '2019-04-01 01:00:00',
              'user_id' => 40092,
              'user_service_id' => $us->id,
              'qnt' => 1,
              'total' => '60.00',
              'end_date' => '2019-04-03 01:00:00',
              'cost' => '900',
              'service_id' => $service->id,
              'withdraw_id' => $wd->id,
              'discount' => 0
          }
    , 'Check withdraw after money back');

    my $balance_after_money_back =  $user->get->{balance};
    is ( $balance_after_money_back, -81.56, 'Check balance after money back');
};

subtest 'Moneyback' => sub {
    my $service = get_service('service')->add(
        name => 'test service',
        cost => '900',
        period => 3,
        category => 'test',
        no_discount => 1,
    );

    Test::MockTime::set_fixed_time('2022-01-01T00:00:00Z');

    my $start_balance = $user->get->{balance};
    is ( $start_balance, -81.56, 'Check start balance');

    my $us = create_service(
        service_id => $service->id,
        months => 3,
    );

    my $wd = $us->withdraw;
    cmp_deeply( scalar $wd->get,
        {
              user_id => 40092,
              bonus => 0,
              months => 3,
              qnt => 1,
              discount => 0,
              create_date => '2022-01-01 00:00:00',
              withdraw_date => '2022-01-01 00:00:00',
              end_date => '2022-03-31 23:59:59',
              cost => 900,
              total => 900,
              user_service_id => $us->id,
              service_id => $service->id,
              withdraw_id => $wd->id,
          }
    , 'Check withdraw');

    Test::MockTime::set_fixed_time('2022-02-01T00:00:00Z');
    $us->set( expire => now );

    money_back( $us );

    cmp_deeply( scalar $wd->get,
        {
              user_id => 40092,
              bonus => 0,
              months => '1.00',
              qnt => 1,
              discount => 0,
              create_date => '2022-01-01 00:00:00',
              withdraw_date => '2022-01-01 00:00:00',
              end_date => '2022-02-01 00:00:00',
              cost => 900,
              total => '300.00',
              user_service_id => $us->id,
              service_id => $service->id,
              withdraw_id => $wd->id,
          }
    , 'Check withdraw after money back');

    my $balance_after_money_back =  $user->get->{balance};
    is ( $balance_after_money_back, -381.56, 'Check balance after money back');
};

done_testing();
