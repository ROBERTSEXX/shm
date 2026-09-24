#!/usr/bin/perl

# ЮKassa
# https://yookassa.ru/developers/api#create_payment
# https://yookassa.ru/developers/using-api/webhooks

use v5.14;
use LWP::UserAgent ();
use HTTP::Request ();
use Core::Utils qw(
    passgen
    encode_json
    decode_json
    get_random_value
);

use SHM qw(:all);

my $PS = 'yookassa';
my $API_URL = 'https://api.yookassa.ru/v3';

our %vars = parse_args();

my $user = SHM->new( skip_check_auth => 1 );

# Копии платежной системы (ключи вида yookassa_1) дополняют настройки основной
sub ps_config {
    my $key = shift || $PS;

    my $config = get_service('config', _id => 'pay_systems');
    my $data = $config ? $config->get_data : {};

    $key = $PS unless ref $data->{ $key } eq 'HASH' &&
        ( $key eq $PS || ( $data->{ $key }->{paysystem} // '' ) eq $PS );

    return ( $key, { %{ $data->{ $PS } || {} }, %{ $data->{ $key } || {} } } );
}

my ( $ps_name, $cfg ) = ps_config( $vars{ps} );

sub api_request {
    my ( $method, $path, $content ) = @_;

    my $req = HTTP::Request->new( $method => "$API_URL/$path" );
    $req->authorization_basic( $cfg->{account_id}, $cfg->{api_key} );
    if ( $content ) {
        $req->header( 'Content-Type' => 'application/json' );
        $req->header( 'Idempotence-Key' => passgen(30) );
        $req->content( encode_json( $content ) );
    }

    my $response = LWP::UserAgent->new( timeout => 15 )->request( $req );
    logger->dump( $response->content );

    return ( $response, $response->is_success ? decode_json( $response->decoded_content ) : undef );
}

unless ( $cfg->{account_id} && $cfg->{api_key} ) {
    print_json({ status => 400, msg => "Error: account_id and api_key required. Please set it in config pay_systems->$ps_name" });
    exit 0;
}

if ( $vars{action} eq 'create' || $vars{action} eq 'payment' ) {
    if ( $vars{user_id} ) {
        $user = $user->id( $vars{user_id} );
        unless ( $user ) {
            print_json({ status => 400, msg => 'Error: unknown user' });
            exit 0;
        }

        if ( $vars{message_id} ) {
            get_service('Transport::Telegram')->deleteMessage( message_id => $vars{message_id} );
        }
    } else {
        $user = SHM->new();
    }

    my $description = get_random_value( $vars{description} || $cfg->{description} ) || 'Пополнение баланса';
    my $amount = $vars{amount} || 100;

    # Повторный платеж по сохраненному способу оплаты
    my $payment_method_id = $vars{action} eq 'payment' ? $user->get_settings->{pay_systems}->{ $PS }->{payment_id} : undef;

    # Старые настройки без send_receipt отправляли чек всегда, когда задан customer_email
    my $receipt;
    if ( $cfg->{send_receipt} // $cfg->{customer_email} ) {
        my $customer_email = $vars{email} || $cfg->{customer_email};
        unless ( $customer_email ) {
            print_json({ status => 400, msg => "Error: customer_email required for receipts. Please set it in config pay_systems->$ps_name" });
            exit 0;
        }

        $receipt = {
            customer => { email => $customer_email },
            items => [{
                description     => $description,
                quantity        => 1,
                amount          => { value => $amount, currency => 'RUB' },
                vat_code        => $cfg->{vat_code} || 1,
                payment_mode    => 'full_payment',
                payment_subject => 'service',
            }],
        };
    }

    my ( $response, $payment ) = api_request( POST => 'payments', {
        metadata    => { user_id => $user->id },
        amount      => { value => $amount, currency => 'RUB' },
        capture     => 'true',
        description => sprintf( '%s [%d]', $description, $user->id ),
        $payment_method_id ? (
            payment_method_id => $payment_method_id,
        ) : (
            $cfg->{save_payments} ? ( save_payment_method => 'true' ) : (),
            confirmation => {
                type       => 'redirect',
                return_url => $cfg->{return_url} || 'https://www.example.com',
            },
        ),
        $receipt ? ( receipt => $receipt ) : (),
    });

    unless ( $payment ) {
        print_header( status => 402 );
        print $response->content;
        exit 0;
    }

    if ( my $location = $payment->{confirmation}->{confirmation_url} ) {
        print_header(
            location => $location,
            status => 301,
        );
    } elsif ( $payment->{status} eq 'succeeded' ) {
        print_json({ status => 200, msg => 'Payment successful' });
    } else {
        my %i16n_ru = (
            insufficient_funds => 'недостаточно средств',
            permission_revoked => 'автосписания запрещены',
        );
        my $reason = $payment->{cancellation_details}->{reason};

        print_json({
            status => 406,
            $reason ? ( msg => $reason ) : (),
            $reason && $i16n_ru{ $reason } ? ( msg_ru => $i16n_ru{ $reason } ) : (),
        });
    }
    exit 0;
}

my %events = (
    'payment.succeeded' => { path => 'payments', status => 'succeeded' },
    'payment.canceled'  => { path => 'payments', status => 'canceled' },
    'refund.succeeded'  => { path => 'refunds',  status => 'succeeded' },
);

my $event = $events{ $vars{event} // '' };
unless ( $event ) {
    print_json({ status => 200, msg => 'unknown event', event => $vars{event} });
    exit 0;
}

my $object_id = ref $vars{object} eq 'HASH' ? $vars{object}->{id} : undef;
unless ( $object_id && $object_id =~ /^[\w-]+$/ ) {
    print_json({ status => 400, msg => 'Error: bad request' });
    exit 0;
}

# Уведомлению не доверяем: получаем объект из API под своими учетными данными
my ( $response, $object ) = api_request( GET => "$event->{path}/$object_id" );
unless ( $object ) {
    logger->error("Can't get $event->{path}/$object_id from YooKassa: " . $response->status_line );
    print_header( status => 502 );
    print_json({ status => 502, msg => 'Error: can not verify notification' });
    exit 0;
}

if ( $object->{status} ne $event->{status} ) {
    print_json({ status => 200, msg => "Object status is $object->{status}, skipped" });
    exit 0;
}

my $user_id = $object->{metadata}->{user_id};
my $amount = $object->{amount}->{value};
my $uniq_key = $object->{id};
my $pay_system_id = $ps_name;

if ( $vars{event} eq 'payment.canceled' ) {
    $pay_system_id .= '-canceled';
    $uniq_key = "canceled-$object->{id}";
    $amount = 0;
}

if ( $vars{event} eq 'refund.succeeded' ) {
    my ( $pay ) = get_service('pay')->_list( where => {
        uniq_key => $object->{payment_id},
    });
    $user_id = $pay ? $pay->{user_id} : undef;

    $pay_system_id .= '-refund';
    $uniq_key = "refund-$object->{id}";
    $amount = -$amount;
}

$pay_system_id .= '-test' if $object->{test};

unless ( $user_id ) {
    print_json({ status => 400, msg => 'User (metadata.user_id) required' });
    exit 0;
}

unless ( $user = $user->id( $user_id ) ) {
    print_json({ status => 404, msg => "User [$user_id] not found" });
    exit 0;
}

unless ( $user->lock( timeout => 10 ) ) {
    print_json({ status => 408, msg => 'The service is locked. Try again later' });
    exit 0;
}

if ( $vars{event} eq 'payment.succeeded' && $object->{payment_method}->{saved} ) {
    $user->set_settings({
        pay_systems => {
            $PS => {
                name       => $object->{payment_method}->{title},
                payment_id => $object->{payment_method}->{id},
            },
        },
    });
}

$user->payment(
    user_id => $user_id,
    money => $amount,
    pay_system_id => $pay_system_id,
    comment => $object,
    uniq_key => $uniq_key,
);

$user->commit;

print_json({ status => 200, msg => 'operation successful' });

exit 0;
