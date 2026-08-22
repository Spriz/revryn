<?php

namespace App\BillingCore;

/** BC-US-153 failure taxonomy: distinguishable failure classes. */
class BillingCoreError extends \RuntimeException {}
class ConfigurationError extends BillingCoreError {}
class AuthenticationError extends BillingCoreError {}
class ContractError extends BillingCoreError {}

class DomainRejection extends BillingCoreError
{
    public function __construct(public readonly string $rejectionCode, string $message)
    {
        parent::__construct("{$rejectionCode}: {$message}");
    }
}
