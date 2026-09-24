#!/usr/bin/perl

# FreeKassa (SCI)
# https://docs.freekassa.net/#section/1.-Vvedenie

use v5.14;
use URI ();
use Digest::MD5 qw( md5_hex );
use Core::Utils ();

use SHM qw(:all);

my $PS = 'freekassa';

# Для POST-форм параметры из адреса (например ?ps=ключ_копии) нужно добавить отдельно
our %vars = parse_args();
%vars = ( Core::Utils::get_uri_args(), %vars );
$vars{ lc $_ } = delete $vars{ $_ } for grep { $_ ne lc $_ } keys %vars;

my $user = SHM->new( skip_check_auth => 1 );

# Копии платежной системы (ключи вида freekassa_1) дополняют настройки основной
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

    my $currency = $cfg->{currency} || 'RUB';
    my $amount = $vars{amount} || 100;

    for ( qw( merchant_id secret_word_1 ) ) {
        unless ( $cfg->{ $_ } ) {
            print_json({ status => 400, msg => "Error: $_ required. Please set it in config pay_systems->$ps_name" });
            exit 0;
        }
    }

    # Номер заказа уникален для каждого платежа и входит в подпись уведомления:
    # из него берем пользователя и по нему защищаемся от повторного зачисления
    my $order_id = sprintf( '%d-%d%03d', $user->id, time, int rand 1000 );

    my $uri = URI->new('https://pay.fk.money/');
    $uri->query_form(
        m        => $cfg->{merchant_id},
        oa       => $amount,
        currency => $currency,
        o        => $order_id,
        s        => md5_hex( join ':', $cfg->{merchant_id}, $amount, $cfg->{secret_word_1}, $currency, $order_id ),
        lang     => $cfg->{lang} || 'ru',
    );

    print_header(
        location => $uri->as_string,
        status => 301,
    );
    exit 0;
}

# Проверка доступности URL оповещения из личного кабинета
if ( $vars{status_check} ) {
    print_header( status => 200, type => 'text/plain' );
    print 'YES';
    exit 0;
}

unless ( $cfg->{merchant_id} && $cfg->{secret_word_2} ) {
    print_json({ status => 400, msg => "Error: merchant_id and secret_word_2 required. Please set it in config pay_systems->$ps_name" });
    exit 0;
}

my $sign = md5_hex( join ':', $vars{merchant_id}, $vars{amount}, $cfg->{secret_word_2}, $vars{merchant_order_id} );

if ( $vars{merchant_id} ne $cfg->{merchant_id} || lc( $vars{sign} // '' ) ne $sign ) {
    print_json({ status => 400, msg => 'Error: incorrect signature' });
    exit 0;
}

my ( $user_id ) = ( $vars{merchant_order_id} // '' ) =~ /^(\d+)-\d+$/;
unless ( $user_id ) {
    print_json({ status => 400, msg => 'Error: incorrect order id' });
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
    money => $vars{amount},
    pay_system_id => $ps_name,
    comment => \%vars,
    uniq_key => $vars{merchant_order_id},
);

$user->commit;

print_header( status => 200, type => 'text/plain' );
print 'YES';

exit 0;
