use v5.14;
use utf8;

# Сквозной тест серверной части SHM Cloud (Core::CloudServer).
# Требует SHM_CLOUD_SERVER=1 на сервере, для проверки клиента (Core::Cloud)
# еще и SHM_CLOUD_URL=http://api/shm/v1/cloud в окружении теста.

use Test::More;
use LWP::UserAgent ();
use HTTP::Request ();
use URI ();
use MIME::Base64 qw( decode_base64 );
use File::Path qw( make_path );
use Core::Utils qw( encode_json decode_json );

my $API = 'http://api/shm/v1';
my %admin = ( login => 'admin', password => 'admin' );

my $ua = LWP::UserAgent->new( timeout => 30 );

sub api {
    my ( $method, $path, %args ) = @_;

    my $uri = URI->new( $API . $path );
    $uri->query_form( %{ $args{query} } ) if $args{query};

    my $req = HTTP::Request->new( $method => $uri );
    $req->authorization_basic( $args{auth}->{login}, $args{auth}->{password} ) if $args{auth};
    if ( $args{data} ) {
        $req->header( 'Content-Type' => 'application/json' );
        $req->content( encode_json( $args{data} ) );
    }

    my $res = $ua->request( $req );
    return (
        code    => $res->code,
        content => $res->decoded_content,
        json    => $res->header('Content-Type') =~ /json/ ? decode_json( $res->decoded_content ) : undef,
    );
}

sub captcha {
    my %r = api( GET => '/cloud/user/captcha' );
    my $captcha = $r{json}->{data}->[0];
    my $svg = decode_base64( $captcha->{image} );
    my $text = join '', $svg =~ m{<text[^>]*>([^<]*)</text>}g;
    my ( $a, $op, $b ) = $text =~ /(\d+)\s*([+-])\s*(\d+)/;
    return ( $captcha->{token}, $op eq '+' ? $a + $b : $a - $b );
}

my %r = api( GET => '/cloud/test' );
plan skip_all => 'SHM_CLOUD_SERVER is not enabled' unless $r{code} == 200;

my $sfx = time . $$;
# services.category - не длиннее 16 символов
my $sub_category = 'cs-' . substr( $sfx, -10 );
my $ps_category = 'cp-' . substr( $sfx, -10 );
my %user = ( login => "cloud$sfx", password => 'cloud-pass-123' );
my $user_id;

subtest 'Setup cloud config and services' => sub {
    api( DELETE => '/admin/config', auth => \%admin, query => { key => 'cloud_server' } );
    %r = api( PUT => '/admin/config', auth => \%admin, data => {
        key   => 'cloud_server',
        value => {
            sub_category => $sub_category,
            ps_category  => $ps_category,
            tg_url       => 'https://t.me/+cloud_test',
        },
    });
    is $r{code}, 200, 'cloud_server config created';
};

my %service;
for (
    [ plan_month => { name => 'Cloud monthly', cost => 300, period => 1, category => $sub_category, allow_to_order => 1 } ],
    [ ps_yoomoney => { name => 'YooMoney module', cost => 500, period => 12, category => $ps_category, allow_to_order => 1, config => { paysystem => 'yoomoney' } } ],
) {
    my ( $key, $data ) = @{ $_ };
    my %s = api( PUT => '/admin/service', auth => \%admin, data => $data );
    $service{ $key } = $s{json}->{data}->[0]->{service_id};
}
my %s = api( PUT => '/admin/service', auth => \%admin, data => {
    name => 'Cloud first month', cost => 100, period => 1, category => $sub_category, allow_to_order => 1, next => $service{plan_month},
});
$service{plan_first} = $s{json}->{data}->[0]->{service_id};

ok $service{ $_ }, "service $_ created" for qw( plan_month plan_first ps_yoomoney );

subtest 'Registration' => sub {
    my ( $token ) = captcha();
    %r = api( PUT => '/cloud/user', data => { %user, captcha_token => $token, captcha_answer => '99' } );
    is $r{code}, 403, 'wrong captcha rejected';
    is $r{json}->{error}, 'Invalid captcha';

    my ( $token2, $answer ) = captcha();
    %r = api( PUT => '/cloud/user', data => { %user, captcha_token => $token2, captcha_answer => $answer } );
    is $r{code}, 200, 'user registered';
    $user_id = $r{json}->{data}->[0]->{user_id};
    ok $user_id, 'user_id returned';
    is $r{json}->{data}->[0]->{login}, $user{login};
    ok !exists $r{json}->{data}->[0]->{password}, 'password is not returned';

    my ( $token3, $answer3 ) = captcha();
    %r = api( PUT => '/cloud/user', data => { %user, captcha_token => $token3, captcha_answer => $answer3 } );
    is $r{code}, 409, 'duplicate login rejected';
    like $r{json}->{error}, qr/already in use/;
};

subtest 'Auth' => sub {
    %r = api( GET => '/cloud/auth', query => { login => $user{login}, password => 'wrong-password' } );
    is $r{code}, 401, 'wrong password rejected';

    %r = api( GET => '/cloud/auth', query => { %user } );
    is $r{code}, 200, 'login ok';
    is $r{json}->{data}->[0]->{user_id}, $user_id;

    %r = api( POST => '/cloud/auth', data => { %user } );
    is $r{code}, 200, 'login with password in request body';

    %r = api( GET => '/cloud/user', auth => \%user );
    is $r{code}, 200, 'user info';
    is $r{json}->{data}->[0]->{login}, $user{login};
    is $r{json}->{data}->[0]->{balance} + 0, 0, 'zero balance';

    %r = api( GET => '/cloud/service/sub/get' );
    is $r{code}, 401, 'basic auth required';
};

subtest 'Subscription' => sub {
    %r = api( GET => '/cloud/service/sub/get', auth => \%user );
    is $r{code}, 404, 'no subscription yet';

    %r = api( GET => '/cloud/service/sub/list', auth => \%user );
    is $r{code}, 200;
    is ref $r{json}, 'ARRAY', 'raw json array';
    my %plans = map { $_->{service_id} => $_ } @{ $r{json} };
    is scalar keys %plans, 2, 'two plans';
    is $plans{ $service{plan_first} }->{price}, 100;
    is $plans{ $service{plan_first} }->{next}, $service{plan_month};
    is $plans{ $service{plan_first} }->{price_next}, 300;
    is $plans{ $service{plan_month} }->{next}, undef;

    %r = api( POST => '/cloud/service/sub/reg', auth => \%user, data => { service_id => $service{ps_yoomoney} } );
    is $r{code}, 404, 'service from other category rejected';

    %r = api( POST => '/cloud/service/sub/reg', auth => \%user, data => { service_id => $service{plan_first} } );
    is $r{code}, 402, 'not enough money';
    is $r{json}->{error}, 'insufficient money';

    %r = api( GET => '/cloud/service/sub/get', auth => \%user );
    is $r{code}, 404, 'unpaid order rolled back';

    %r = api( PUT => '/admin/user/payment', auth => \%admin, data => { user_id => $user_id, money => 1000, pay_system_id => 'manual' } );
    is $r{code}, 200, 'balance topped up';

    %r = api( POST => '/cloud/service/sub/reg', auth => \%user, data => { service_id => $service{plan_first} } );
    is $r{code}, 200, 'subscription ordered';
    is $r{json}->{service_id}, $service{plan_first};
    is $r{json}->{next}, $service{plan_month}, 'renewal to the next plan';

    %r = api( GET => '/cloud/service/sub/get', auth => \%user );
    is $r{code}, 200;
    is $r{json}->{status}, 'ACTIVE', 'subscription is active';
    ok $r{json}->{expire}, 'expire is set';
    is $r{json}->{tg_url}, 'https://t.me/+cloud_test', 'tg_url for active subscription';

    %r = api( POST => '/cloud/service/sub/reg', auth => \%user, data => { service_id => $service{plan_month} } );
    is $r{code}, 409, 'second subscription rejected';

    %r = api( POST => '/cloud/service/sub/renewal', auth => \%user, data => { service_id => -1 } );
    is $r{code}, 200;
    is $r{json}->{next}, -1, 'renewal disabled';

    %r = api( POST => '/cloud/service/sub/renewal', auth => \%user, data => { service_id => $service{plan_first} } );
    is $r{json}->{next}, $service{plan_first}, 'renewal with the same plan';

    %r = api( POST => '/cloud/service/sub/renewal', auth => \%user, data => { service_id => $service{plan_month} } );
    is $r{json}->{next}, $service{plan_month}, 'renewal with other plan';
};

subtest 'Pay systems' => sub {
    %r = api( GET => '/cloud/service/paysystems/list', auth => \%user );
    is $r{code}, 200;
    my %ps = map { $_->{name} => $_ } @{ $r{json} };
    ok $ps{yoomoney}, 'yoomoney in catalog';
    ok $ps{freekassa}, 'freekassa in catalog';
    is $ps{yoomoney}->{price}, 500;
    is $ps{yoomoney}->{paid}, 0;
    is $ps{freekassa}->{price}, 0, 'module without service is free';
    ok scalar @{ $ps{yoomoney}->{fields} }, 'settings schema';
    ok $ps{yoomoney}->{version}, 'version';

    %r = api( GET => '/cloud/service/paysystems/download', auth => \%user, query => { ps => 'yoomoney' } );
    is $r{code}, 403, 'paid module is not downloadable before purchase';

    %r = api( GET => '/cloud/service/paysystems/download', auth => \%user, query => { ps => 'unknown' } );
    is $r{code}, 404, 'unknown module';

    %r = api( GET => '/cloud/service/paysystems/download', auth => \%user, query => { ps => 'freekassa', arch => 'x86_64' } );
    is $r{code}, 200, 'free module downloaded';
    like $r{content}, qr{^#!/usr/bin/perl}, 'module content';

    %r = api( GET => '/cloud/service/paysystems/order', auth => \%user, query => { ps => 'yoomoney' } );
    is $r{code}, 200, 'module purchased';
    is $r{json}->{paid}, 1;

    %r = api( GET => '/cloud/user', auth => \%user );
    is $r{json}->{data}->[0]->{balance} + 0, 400, 'balance after purchases';

    %r = api( GET => '/cloud/service/paysystems/list', auth => \%user );
    my ( $yoomoney ) = grep { $_->{name} eq 'yoomoney' } @{ $r{json} };
    is $yoomoney->{paid}, 1, 'module is paid';

    %r = api( GET => '/cloud/service/paysystems/order', auth => \%user, query => { ps => 'yoomoney' } );
    is $r{code}, 200, 'repeated order does not charge';
    %r = api( GET => '/cloud/user', auth => \%user );
    is $r{json}->{data}->[0]->{balance} + 0, 400, 'balance unchanged';

    %r = api( GET => '/cloud/service/paysystems/download', auth => \%user, query => { ps => 'yoomoney' } );
    is $r{code}, 200, 'paid module downloaded';
    like $r{content}, qr{yoomoney}, 'module content';
};

use SHM;
use Core::System::ServiceManager qw( get_service );
my $shm = SHM->new( user_id => 1 );
my $cache = get_service('Core::System::Cache');

subtest 'Currencies' => sub {
    $cache->set_json( 'cloud_server_currencies', {
        checked => time,
        list => {
            USD => { currency => 'USD', name => 'Доллар США', nominal => 1, value => 90, updated => '2026-01-01T00:00:00' },
            KZT => { currency => 'KZT', name => 'Казахстанских тенге', nominal => 100, value => 0.18, updated => '2026-01-01T00:00:00' },
        },
    }, 0 );

    %r = api( GET => '/cloud/service/currencies/list', auth => \%user );
    is $r{code}, 200;
    is $r{json}->{USD}->{value}, 90;
    is $r{json}->{USD}->{currency}, 'USD';
    is $r{json}->{USD}->{name}, 'Доллар США';
    is $r{json}->{KZT}->{nominal}, 100;
    is $r{json}->{XTR}->{value}, 1.17, 'Telegram Stars rate from USD';
    ok !exists $r{json}->{USD}->{addition_type}, 'no modifier';

    %r = api( POST => '/cloud/service/currencies/list', auth => \%user, data => {
        format => 'json',
        currencies => { USD => { addition_type => 'percent', addition_value => 5 } },
    });
    is $r{code}, 200, 'modifier saved';
    is $r{json}->{USD}->{addition_type}, 'percent';
    is $r{json}->{USD}->{addition_value}, 5;

    %r = api( GET => '/cloud/service/currencies/list', auth => \%user );
    is $r{json}->{USD}->{addition_type}, 'percent', 'modifier persisted';

    %r = api( POST => '/cloud/service/currencies/list', auth => \%user, data => {
        currencies => { USD => { addition_type => 'bad', addition_value => 5 } },
    });
    is $r{code}, 400, 'incorrect modifier type';

    %r = api( POST => '/cloud/service/currencies/list', auth => \%user, data => {
        currencies => { XXX => { addition_type => 'fixed', addition_value => 5 } },
    });
    is $r{code}, 400, 'unknown currency';

    %r = api( POST => '/cloud/service/currencies/list', auth => \%user, data => {
        currencies => { USD => { addition_type => '', addition_value => 0 } },
    });
    ok !exists $r{json}->{USD}->{addition_type}, 'modifier removed';
};

subtest 'IP binding' => sub {
    %r = api( POST => '/admin/user', auth => \%admin, data => { user_id => $user_id, settings => { cloud => { ip => '203.0.113.1' } } } );
    is $r{code}, 200, 'bound to other IP';

    %r = api( GET => '/cloud/service/sub/get', auth => \%user );
    is $r{code}, 403, 'request from other IP rejected';
    is $r{json}->{error}, 'Login from this IP is prohibited';

    %r = api( GET => '/cloud/auth', query => { %user } );
    is $r{code}, 403, 'login from other IP rejected';

    %r = api( POST => '/cloud/auth/reset', data => { login => $user{login}, password => 'wrong-password' } );
    is $r{code}, 401, 'reset requires password';

    %r = api( POST => '/cloud/auth/reset', data => { %user } );
    is $r{code}, 200, 'IP binding reset';

    %r = api( GET => '/cloud/service/sub/get', auth => \%user );
    is $r{code}, 200, 'request allowed after reset';
};

SKIP: {
    skip 'SHM_CLOUD_URL is not pointing to this server', 1 unless ( $ENV{SHM_CLOUD_URL} // '' ) eq "$API/cloud";

    subtest 'SHM client (Core::Cloud) works with own cloud' => sub {
        my $cloud = get_service('Cloud');

        my $cloud_user = $cloud->login_user( %user );
        is $cloud_user->{login}, $user{login}, 'client login';

        is get_service('Cloud::Subscription')->check_subscription, 1, 'client sees active subscription';

        my $sub = $cloud->proxy( uri => 'service/sub/get', method => 'GET' );
        is $sub->{status}, 'ACTIVE', 'proxy to cloud';

        my $currencies = get_service('Cloud::Currency')->currencies( no_cache => 1 );
        is $currencies->{USD}->{value}, 90, 'client currencies';
        is get_service('Cloud::Currency')->convert( from => 'USD', to => 'RUB', amount => 10 ), 900, 'client conversion';

        my $task = bless { settings => { ps_name => 'yoomoney' } }, 'CloudTestTask';
        my $file = get_service('Cloud::Jobs')->ps_file_name('yoomoney');
        unlink $file;

        # Каталог создает job_download_all_paystems перед постановкой задач
        my ( $dir ) = $file =~ m{^(.+)/[^/]+$};
        my @created_dirs = make_path( $dir );

        my ( $status, $info ) = get_service('Cloud::Jobs')->job_download_paystem( $task );
        is $status, 1, 'client downloaded pay system' or diag explain $info;
        ok -x $file, 'pay system is executable';
        unlink $file;
        rmdir $_ for reverse @created_dirs;

        get_service('Cloud::Subscription')->clear_subscription_cache;
        $cloud->logout_user;
        $cache->delete('currencies');
        $cache->delete('currencies_timestamp');
    };
}

$cache->delete('cloud_server_currencies');
api( DELETE => '/admin/config', auth => \%admin, query => { key => 'cloud_server' } );

done_testing();

package CloudTestTask;
sub settings { shift->{settings} }

1;
