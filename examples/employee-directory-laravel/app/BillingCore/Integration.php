<?php

namespace App\BillingCore;

/** Integration-mode switch (BC-US-152 final milestone, BC-US-153). */
final class Integration
{
    private static function read(string $key): string
    {
        // env() covers .env-file values; getenv/$_SERVER cover process env
        // (artisan serve workers do not reliably inherit the latter).
        return (string) (env($key) ?: getenv($key) ?: ($_SERVER[$key] ?? ''));
    }

    public static function enabled(): bool
    {
        return self::read('PERSONALE_BILLING') === 'integrated';
    }

    public static function config(): array
    {
        return [
            'url' => self::read('BILLING_CORE_URL') ?: 'http://localhost:4000',
            'token' => self::read('BILLING_CORE_TOKEN'),
            'team_id' => self::read('BILLING_CORE_TEAM_ID'),
        ];
    }
}
