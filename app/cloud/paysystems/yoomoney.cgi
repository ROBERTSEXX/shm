#!/usr/bin/perl

# ЮMoney: прием переводов на кошелек через форму quickpay
# https://yoomoney.ru/docs/payment-buttons/using-api/forms
# https://yoomoney.ru/docs/wallet/using-api/notification-p2p-incoming

use v5.14;
use LWP::UserAgent ();
use Digest::SHA qw( sha1_hex );
use Core::Utils qw( encode_utf8 );

use SHM qw(:all);

my $PS = 'yoomoney';

# Для POST-форм параметры из адреса (например ?ps=ключ_копии) нужно добавить отдельно
our %vars = parse_args();
%vars = ( Core::Utils::get_uri_args(), %vars );

my $user = SHM->new( skip_check_auth => 1 );

# Копии платежной системы (ключи вида yoomoney_1) дополняют настройки основной
sub ps_config {
    my $key = shift || $PS;

    my $config = get_service('config', _id => 'pay_systems');
    my $data = $config ? $config->get_data : {};

    $key = $PS unless ref $data->{ $key } eq 'HASH' &&
        ( $key eq $PS || ( $data->{ $key }->{paysystem} // '' ) eq $PS );

    return ( $key, { %{ $data->{ $PS } || {} }, %{ $data->{ $key } || {} } } );
}

my ( $ps_name, $cfg ) = ps_config( $vars{ps} );

if ( $vars{action} eq 'create' ) {
    $user = $vars{user_id} ? SHM->new( user_id => $vars{user_id} ) : SHM->new();

    if ( $vars{message_id} ) {
        get_service('Transport::Telegram')->deleteMessage( message_id => $vars{message_id} );
    }

    unless ( $cfg->{account} ) {
        print_json({ status => 400, msg => "Error: account required. Please set it in config pay_systems->$ps_name" });
        exit 0;
    }

    my $lwp = LWP::UserAgent->new( timeout => 10 );
    my $response = $lwp->post(
        'https://yoomoney.ru/quickpay/confirm',
        Content_Type => 'form-data',
        Content => encode_utf8([
            'quickpay-form' => 'button',
            receiver        => $cfg->{account},
            label           => $user->id,
            sum             => $vars{amount} || 100,
            $cfg->{payment_type} ? ( paymentType => $cfg->{payment_type} ) : (),
            $cfg->{success_url} ? ( successURL => $cfg->{success_url} ) : (),
        ]),
    );

    if ( my $location = $response->header('location') ) {
        print_header(
            location => $location,
            status => 301,
        );
    } else {
        print_header( status => 503 );
        print $response->content;
    }
    exit 0;
}

my $secret = $cfg->{secret};
unless ( $secret ) {
    print_json({ status => 400, msg => "Error: secret required. Please set it in config pay_systems->$ps_name" });
    exit 0;
}

my $digest = sha1_hex( join('&',
    @vars{ qw/notification_type operation_id amount currency datetime sender codepro/ },
    $secret,
    $vars{label},
));

if ( lc( $vars{sha1_hash} // '' ) ne $digest ) {
    print_json({ status => 400, msg => 'Error: incorrect signature' });
    exit 0;
}

if ( $vars{test_notification} && $vars{test_notification} ne 'false' ) {
    print_json({ status => 200, msg => 'Test OK' });
    exit 0;
}

# Платеж заморожен (например, требуется действие получателя) - зачислим при повторном уведомлении
if ( ( $vars{unaccepted} // '' ) eq 'true' ) {
    print_json({ status => 200, msg => 'Payment is not accepted yet' });
    exit 0;
}

my $user_id = $vars{label};
unless ( $user_id ) {
    print_json({ status => 400, msg => 'User (label) required' });
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

$user->payment(
    user_id => $user_id,
    money => $vars{withdraw_amount} || $vars{amount},
    pay_system_id => $ps_name,
    comment => \%vars,
    uniq_key => $vars{operation_id},
);

$user->commit;

print_json({ status => 200, msg => 'Payment successful' });

exit 0;
