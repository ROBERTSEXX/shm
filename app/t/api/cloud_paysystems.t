use v5.14;
use utf8;

# Проверка уведомлений о платежах в модулях из каталога облака (cloud/paysystems):
# зачисление с верной подписью, отказ с неверной и защита от повторного зачисления.

use Test::More;
use LWP::UserAgent ();
use HTTP::Request ();
use HTTP::Request::Common qw( POST );
use URI ();
use File::Copy qw( copy );
use File::Path qw( make_path );
use Digest::SHA qw( sha1_hex sha256 hmac_sha256_hex hmac_sha256_base64 );
use Digest::MD5 qw( md5_hex );
use MIME::Base64 qw( encode_base64 );
use Core::Utils qw( encode_json decode_json );

my $API = 'http://api/shm';
my %admin = ( login => 'admin', password => 'admin' );
my $SRC_DIR = "$ENV{SHM_ROOT_DIR}/cloud/paysystems";
my $PS_DIR = "$ENV{SHM_ROOT_DIR}/data/pay_systems";

plan skip_all => 'Pay systems catalog not found' unless -d $SRC_DIR;
plan skip_all => 'Legacy pay systems path is enabled' if $ENV{LEGACY_PAYSYSTEMS_PATH};

my $ua = LWP::UserAgent->new( timeout => 30 );

sub request {
    my $req = shift;
    my $res = $ua->request( $req );
    return (
        code    => $res->code,
        content => $res->decoded_content,
        json    => ( $res->header('Content-Type') // '' ) =~ /json/ ? decode_json( $res->decoded_content ) : undef,
    );
}

sub admin_api {
    my ( $method, $path, $data, $query ) = @_;
    my $uri = URI->new( "$API/v1$path" );
    $uri->query_form( %{ $query } ) if $query;
    my $req = HTTP::Request->new( $method => $uri );
    $req->authorization_basic( $admin{login}, $admin{password} );
    if ( $data ) {
        $req->header( 'Content-Type' => 'application/json' );
        $req->content( encode_json( $data ) );
    }
    return request( $req );
}

sub balance {
    my %r = admin_api( GET => '/admin/user', undef, { user_id => shift } );
    return $r{json}->{data}->[0]->{balance} + 0;
}

sub ps_url {
    my ( $name, $key ) = @_;
    return "$API/pay_systems/$name.cgi?ps=$key";
}

my $sfx = time . $$;

my %r = admin_api( PUT => '/admin/user', { login => "pstest$sfx", password => 'ps-test-pass-123' } );
my $user_id = $r{json}->{data}->[0]->{user_id};
ok $user_id, 'test user created';

# Ставим модули из каталога, если они еще не установлены
my @created_dirs = make_path( $PS_DIR );
my @installed;
for my $name ( qw( yoomoney freekassa cryptopay wallet yookassa ) ) {
    my $file = "$PS_DIR/$name.cgi";
    next if -e $file;
    copy( "$SRC_DIR/$name.cgi", $file ) or die "Can't copy $name: $!";
    chmod 0755, $file;
    push @installed, $file;
}

# Настройки кладем в копии (ключи <name>_t<sfx>): заодно проверяем параметр ps
my %key = map { $_ => "${_}_t$sfx" } qw( yoomoney freekassa cryptopay wallet yookassa );
my %settings = (
    $key{yoomoney}  => { paysystem => 'yoomoney', account => '4100000000000000', secret => 'ym-secret' },
    $key{freekassa} => { paysystem => 'freekassa', merchant_id => '777', secret_word_1 => 'fk-secret-1', secret_word_2 => 'fk-secret-2' },
    $key{cryptopay} => { paysystem => 'cryptopay', api_key => 'cp-api-key' },
    $key{wallet}    => { paysystem => 'wallet', api_key => 'wallet-api-key' },
    $key{yookassa}  => { paysystem => 'yookassa', account_id => '123456', api_key => 'test_fake_key' },
);

%r = admin_api( GET => '/admin/config', undef, { key => 'pay_systems' } );
if ( @{ $r{json}->{data} || [] } ) {
    my $req = HTTP::Request->new( POST => "$API/v1/admin/config/pay_systems" );
    $req->authorization_basic( $admin{login}, $admin{password} );
    $req->header( 'Content-Type' => 'application/json' );
    $req->content( encode_json( \%settings ) );
    %r = request( $req );
} else {
    %r = admin_api( PUT => '/admin/config', { key => 'pay_systems', value => \%settings } );
}
is $r{code}, 200, 'pay systems configured';

subtest 'YooMoney' => sub {
    my $balance = balance( $user_id );
    my %n = (
        notification_type => 'p2p-incoming',
        operation_id      => "op-$sfx",
        amount            => '98.00',
        withdraw_amount   => '100.00',
        currency          => '643',
        datetime          => '2026-01-01T00:00:00Z',
        sender            => '41001000040',
        codepro           => 'false',
        label             => $user_id,
    );
    my $sign = sha1_hex( join '&', @n{ qw/notification_type operation_id amount currency datetime sender codepro/ }, 'ym-secret', $n{label} );

    %r = request( POST ps_url( yoomoney => $key{yoomoney} ), [ %n, sha1_hash => 'bad' ] );
    is balance( $user_id ), $balance, 'wrong signature rejected';

    %r = request( POST ps_url( yoomoney => $key{yoomoney} ), [ %n, sha1_hash => $sign ] );
    is $r{json}->{status}, 200, 'notification accepted' or diag $r{content};
    is balance( $user_id ), $balance + 100, 'balance credited';

    %r = request( POST ps_url( yoomoney => $key{yoomoney} ), [ %n, sha1_hash => $sign ] );
    is balance( $user_id ), $balance + 100, 'repeated notification is not credited';
};

subtest 'FreeKassa' => sub {
    my $balance = balance( $user_id );
    my $order_id = "$user_id-$sfx";
    my %n = ( MERCHANT_ID => '777', AMOUNT => '150', intid => "fk$sfx", MERCHANT_ORDER_ID => $order_id );
    my $sign = md5_hex( join ':', '777', '150', 'fk-secret-2', $order_id );

    %r = request( POST ps_url( freekassa => $key{freekassa} ), [ %n, SIGN => md5_hex('bad') ] );
    is balance( $user_id ), $balance, 'wrong signature rejected';

    %r = request( POST ps_url( freekassa => $key{freekassa} ), [ %n, MERCHANT_ORDER_ID => $user_id, SIGN => md5_hex( join ':', '777', '150', 'fk-secret-2', $user_id ) ] );
    is balance( $user_id ), $balance, 'order id without unique part rejected';

    %r = request( POST ps_url( freekassa => $key{freekassa} ), [ %n, SIGN => $sign ] );
    is $r{content}, 'YES', 'notification accepted';
    is balance( $user_id ), $balance + 150, 'balance credited';

    %r = request( POST ps_url( freekassa => $key{freekassa} ), [ %n, intid => "other$sfx", SIGN => $sign ] );
    is balance( $user_id ), $balance + 150, 'replay with other intid is not credited';

    %r = request( POST ps_url( freekassa => $key{freekassa} ), [ status_check => 1 ] );
    is $r{content}, 'YES', 'status check';
};

subtest 'Crypto Pay' => sub {
    my $balance = balance( $user_id );
    my $body = encode_json({
        update_id    => 1,
        update_type  => 'invoice_paid',
        request_date => '2026-01-01T00:00:00.000Z',
        payload      => {
            invoice_id  => $sfx,
            status      => 'paid',
            amount      => '250',
            fiat        => 'RUB',
            payload     => "$user_id",
            description => "Пополнение баланса [$user_id]",
        },
    });

    my $req = HTTP::Request->new( POST => ps_url( cryptopay => $key{cryptopay} ) );
    $req->header( 'Content-Type' => 'application/json' );
    $req->header( 'Crypto-Pay-Api-Signature' => hmac_sha256_hex( $body, sha256('wrong-key') ) );
    $req->content( $body );
    %r = request( $req );
    is balance( $user_id ), $balance, 'wrong signature rejected';

    $req->header( 'Crypto-Pay-Api-Signature' => hmac_sha256_hex( $body, sha256('cp-api-key') ) );
    %r = request( $req );
    is $r{json}->{status}, 200, 'notification accepted' or diag $r{content};
    is balance( $user_id ), $balance + 250, 'balance credited';

    %r = request( $req );
    is balance( $user_id ), $balance + 250, 'repeated notification is not credited';
};

subtest 'Wallet Pay' => sub {
    my $balance = balance( $user_id );
    my $url = ps_url( wallet => $key{wallet} );
    my ( $path ) = $url =~ m{^https?://[^/]+(/.*)$};
    my $body = encode_json([{
        eventDateTime => '2026-01-01T00:00:00.000Z',
        eventId       => 1,
        type          => 'ORDER_PAID',
        payload       => {
            id          => 1,
            externalId  => "ORD-$user_id-$sfx",
            orderAmount => { amount => '300', currencyCode => 'RUB' },
            customData  => "$user_id",
        },
    }]);
    my $timestamp = '1790000000000';

    my $sign = sub {
        my $hmac = hmac_sha256_base64( join( '.', 'POST', $path, $timestamp, encode_base64( $body, '' ) ), shift );
        $hmac .= '=' while length( $hmac ) % 4;
        return $hmac;
    };

    my $req = HTTP::Request->new( POST => $url );
    $req->header( 'Content-Type' => 'application/json' );
    $req->header( 'WalletPay-Timestamp' => $timestamp );
    $req->header( 'WalletPay-Signature' => $sign->('wrong-key') );
    $req->content( $body );
    %r = request( $req );
    is balance( $user_id ), $balance, 'wrong signature rejected';

    $req->header( 'WalletPay-Signature' => $sign->('wallet-api-key') );
    %r = request( $req );
    is $r{json}->{status}, 200, 'notification accepted' or diag $r{content};
    is balance( $user_id ), $balance + 300, 'balance credited';

    %r = request( $req );
    is balance( $user_id ), $balance + 300, 'repeated notification is not credited';
};

subtest 'YooKassa' => sub {
    my $balance = balance( $user_id );

    # Поддельное уведомление: объект не подтверждается API ЮKassa (неверные учетные данные)
    my $req = HTTP::Request->new( POST => ps_url( yookassa => $key{yookassa} ) );
    $req->header( 'Content-Type' => 'application/json' );
    $req->header( 'X-Real-IP' => '185.71.76.1' );
    $req->content( encode_json({
        type   => 'notification',
        event  => 'payment.succeeded',
        object => {
            id        => "fake-$sfx",
            status    => 'succeeded',
            paid      => \1,
            amount    => { value => '1000.00', currency => 'RUB' },
            metadata  => { user_id => "$user_id" },
            recipient => { account_id => '123456' },
        },
    }));
    %r = request( $req );
    isnt $r{json}->{status}, 200, 'unverified notification rejected';
    is balance( $user_id ), $balance, 'forged payment is not credited';

    $req->content( encode_json({ event => 'payment.succeeded', object => { id => '../../me' } }) );
    %r = request( $req );
    is $r{json}->{status}, 400, 'incorrect object id rejected';
};

admin_api( DELETE => '/admin/config/pay_systems', undef, { value => $_ } ) for values %key;
unlink $_ for @installed;
rmdir $_ for reverse @created_dirs;

done_testing();
