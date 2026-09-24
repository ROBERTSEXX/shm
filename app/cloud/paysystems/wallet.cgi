#!/usr/bin/perl

# Wallet Pay (кошелек в Telegram)
# https://docs.wallet.tg/pay/#tag/Order/operation/create
# https://docs.wallet.tg/pay/#section/Webhook

use v5.14;
use LWP::UserAgent ();
use HTTP::Request ();
use MIME::Base64 qw( encode_base64 );
use Digest::SHA qw( hmac_sha256_base64 );
use Core::Utils qw(
    passgen
    encode_json
    decode_json
);
use CGI ();

use SHM qw(:all);

my $PS = 'wallet';

our %vars = parse_args();

my $user = SHM->new( skip_check_auth => 1 );

# Копии платежной системы (ключи вида wallet_1) дополняют настройки основной
sub ps_config {
    my $key = shift || $PS;

    my $config = get_service('config', _id => 'pay_systems');
    my $data = $config ? $config->get_data : {};

    $key = $PS unless ref $data->{ $key } eq 'HASH' &&
        ( $key eq $PS || ( $data->{ $key }->{paysystem} // '' ) eq $PS );

    return ( $key, { %{ $data->{ $PS } || {} }, %{ $data->{ $key } || {} } } );
}

my ( $ps_name, $cfg ) = ps_config( $vars{ps} );

# Имена настроек из прежней версии модуля
$cfg->{currency_code}            //= $cfg->{currencyCode};
$cfg->{auto_conversion_currency} //= $cfg->{autoConversionCurrency};
$cfg->{return_url}               //= $cfg->{returnUrl};
$cfg->{fail_return_url}          //= $cfg->{failReturnUrl};

unless ( $cfg->{api_key} ) {
    print_json({ status => 400, msg => "Error: api_key required. Please set it in config pay_systems->$ps_name" });
    exit 0;
}

if ( $vars{action} eq 'create' ) {
    $user = $vars{user_id} ? SHM->new( user_id => $vars{user_id} ) : SHM->new();

    if ( $vars{message_id} ) {
        get_service('Transport::Telegram')->deleteMessage( message_id => $vars{message_id} );
    }

    my $description = $cfg->{description} || $vars{description} || 'Пополнение баланса';

    my $req = HTTP::Request->new( POST => 'https://pay.wallet.tg/wpay/store-api/v1/order' );
    $req->header( 'Content-Type' => 'application/json' );
    $req->header( 'Wpay-Store-Api-Key' => $cfg->{api_key} );
    $req->header( 'User-Agent' => 'SHM' );
    $req->content( encode_json({
        amount => {
            currencyCode => $cfg->{currency_code} || 'RUB',
            amount       => $vars{amount} || 100,
        },
        $cfg->{auto_conversion_currency} ? ( autoConversionCurrency => $cfg->{auto_conversion_currency} ) : (),
        description    => sprintf( '%s [%d]', $description, $user->id ),
        returnUrl      => $cfg->{return_url} || 'https://t.me/wallet',
        failReturnUrl  => $cfg->{fail_return_url} || 'https://t.me/wallet',
        externalId     => sprintf( 'ORD-%d-%d-%s', $user->id, time, passgen(5) ),
        timeoutSeconds => 10800,
        customerTelegramUserId => $user->get_settings->{telegram}->{chat_id},
        customData     => $user->id,
    }));

    my $response = LWP::UserAgent->new( timeout => 10 )->request( $req );
    my $data = $response->is_success ? decode_json( $response->decoded_content ) : undef;

    if ( $data && ( my $location = $data->{data}->{directPayLink} ) ) {
        print_header(
            location => $location,
            status => 301,
        );
    } else {
        print_header( status => $response->is_success ? 503 : $response->code );
        print $response->content;
    }
    exit 0;
}

# Подпись: Base64(HMAC-SHA256("METHOD.URI_PATH.TIMESTAMP.Base64(body)", api_key))
my $body = CGI->new->param('POSTDATA') // '';
my $string = join '.', $ENV{REQUEST_METHOD}, $ENV{REQUEST_URI}, $ENV{HTTP_WALLETPAY_TIMESTAMP} // '', encode_base64( $body, '' );

my $hmac = hmac_sha256_base64( $string, $cfg->{api_key} );
$hmac .= '=' while length( $hmac ) % 4;

if ( ( $ENV{HTTP_WALLETPAY_SIGNATURE} // '' ) ne $hmac ) {
    logger->error("Wallet Pay: signature doesn't match");
    print_json({ status => 400, msg => 'Error: bad request' });
    exit 0;
}

my $events = $vars{DATA};
unless ( ref $events eq 'ARRAY' ) {
    print_json({ status => 400, msg => 'Error: bad request' });
    exit 0;
}

for my $event ( @{ $events } ) {
    next unless ( $event->{type} // '' ) eq 'ORDER_PAID';

    my $payload = $event->{payload} || {};
    my $user_id = $payload->{customData};

    my $customer = $user_id ? $user->id( $user_id ) : undef;
    unless ( $customer ) {
        logger->error("Wallet Pay: user not found for order $payload->{externalId}");
        next;
    }

    unless ( $customer->lock( timeout => 10 ) ) {
        print_json({ status => 408, msg => 'The service is locked. Try again later' });
        exit 0;
    }

    $customer->payment(
        user_id => $user_id,
        money => $payload->{orderAmount}->{amount},
        pay_system_id => $ps_name,
        comment => $event,
        uniq_key => $payload->{externalId},
    );
}

$user->commit;

print_json({ status => 200, msg => 'payment successful' });

exit 0;
