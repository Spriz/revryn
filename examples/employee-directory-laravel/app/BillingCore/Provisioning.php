<?php

namespace App\BillingCore;

use App\Models\BillingCoreLink;
use App\Models\Organization;

/**
 * Idempotent provisioning through the public GraphQL contract only
 * (BC-US-152 final milestone). ANNUAL PREPAID plan: 12-month interval,
 * in-advance, per active employee; the app's minimum-seat commitment is
 * its commercial rule and flows through as the billable quantity.
 */
final class Provisioning
{
    public const PRODUCT_CODE = 'personale-seat';
    public const PLAN_CODE = 'personalehuset';
    public const SEAT_PRICE_YEAR_MAJOR = '599.00';

    private static function problemFragments(): string
    {
        return '... on ValidationProblem { code message } ... on AuthorizationProblem { code message }';
    }

    public static function billableSeats(Organization $organization): int
    {
        return max($organization->activeEmployees(), $organization->minimum_seats);
    }

    public static function ensurePlanVersion(Client $client): string
    {
        $products = $client->execute(
            'query($t: ID!, $f: Int){ products(teamId: $t, first: $f){ edges { node { id code } } } }',
            ['t' => $client->teamId, 'f' => 100],
        );
        foreach ($products['products']['edges'] as $edge) {
            if ($edge['node']['code'] === self::PRODUCT_CODE) {
                $link = BillingCoreLink::whereNotNull('plan_version_ref')->first();
                if ($link) {
                    return $link->plan_version_ref;
                }
                throw new ContractError('product exists but no recorded plan version');
            }
        }

        $fragments = self::problemFragments();
        $product = $client->mutate('createProduct',
            "mutation(\$input: CreateProductInput!){ createProduct(input: \$input){ __typename ... on CreateProductSuccess { product { id } } {$fragments} } }",
            ['input' => [
                'teamId' => $client->teamId, 'code' => self::PRODUCT_CODE,
                'name' => 'Personalehuset seat', 'recognitionMode' => 'OVER_TIME',
                'servicePeriodSource' => 'billing_period',
                'clientMutationId' => 'personale:product',
            ]]);

        $plan = $client->mutate('createPlan',
            "mutation(\$input: CreatePlanInput!){ createPlan(input: \$input){ __typename ... on CreatePlanSuccess { plan { id } } {$fragments} } }",
            ['input' => [
                'teamId' => $client->teamId, 'code' => self::PLAN_CODE,
                'name' => 'Personalehuset', 'clientMutationId' => 'personale:plan',
            ]]);

        $version = $client->mutate('createPlanVersion',
            "mutation(\$input: CreatePlanVersionInput!){ createPlanVersion(input: \$input){ __typename ... on CreatePlanVersionSuccess { planVersion { id } } {$fragments} } }",
            ['input' => [
                'teamId' => $client->teamId, 'planId' => $plan['plan']['id'],
                'currency' => 'DKK', 'intervalUnit' => 'MONTH', 'intervalCount' => 12,
                'billingTiming' => 'IN_ADVANCE',
                'components' => [[
                    'code' => 'seat', 'productId' => $product['product']['id'],
                    'pricingDefinition' => ['fixedRecurring' => ['unitPrice' => self::SEAT_PRICE_YEAR_MAJOR]],
                    'prorationPolicy' => 'prorate', 'ordinal' => 1,
                ]],
                'clientMutationId' => 'personale:version',
            ]]);
        $versionId = $version['planVersion']['id'];

        $client->mutate('publishPlanVersion',
            "mutation(\$input: PublishPlanVersionInput!){ publishPlanVersion(input: \$input){ __typename ... on PublishPlanVersionSuccess { planVersion { id } } {$fragments} } }",
            ['input' => [
                'teamId' => $client->teamId, 'planVersionId' => $versionId,
                'clientMutationId' => 'personale:publish',
            ]]);

        return $versionId;
    }

    public static function ensureProvisioned(Organization $organization, ?Client $client = null): BillingCoreLink
    {
        $link = BillingCoreLink::where('organization_id', $organization->id)->first();
        if ($link) {
            return $link;
        }

        $client ??= new Client();
        $planVersionId = self::ensurePlanVersion($client);
        $fragments = self::problemFragments();

        $customer = $client->mutate('upsertCustomer',
            "mutation(\$input: UpsertCustomerInput!){ upsertCustomer(input: \$input){ __typename ... on UpsertCustomerSuccess { customer { id } } {$fragments} ... on VersionConflict { expectedVersion actualVersion } } }",
            ['input' => [
                'teamId' => $client->teamId, 'externalId' => "personale-{$organization->slug}",
                'legalName' => $organization->name, 'country' => 'DK',
                'email' => "billing+{$organization->slug}@personalehuset.example",
                'idempotencyKey' => "personale-customer-{$organization->slug}",
                'clientMutationId' => "personale:customer-{$organization->slug}",
            ]]);

        $contract = $client->mutate('createContract',
            "mutation(\$input: CreateContractInput!){ createContract(input: \$input){ __typename ... on CreateContractSuccess { contract { id } } {$fragments} } }",
            ['input' => [
                'teamId' => $client->teamId, 'customerId' => $customer['customer']['id'],
                'currency' => 'DKK', 'startDate' => now()->toDateString(),
                'externalReference' => "personale-{$organization->slug}",
                'clientMutationId' => "personale:contract-{$organization->slug}",
            ]]);

        $subscription = $client->mutate('createSubscription',
            "mutation(\$input: CreateSubscriptionInput!){ createSubscription(input: \$input){ __typename ... on CreateSubscriptionSuccess { subscription { id } } {$fragments} ... on IdempotencyConflict { code message } } }",
            ['input' => [
                'teamId' => $client->teamId, 'contractId' => $contract['contract']['id'],
                'externalId' => "personale-{$organization->slug}",
                'planVersionId' => $planVersionId, 'startsOn' => now()->toDateString(),
                'quantity' => (string) self::billableSeats($organization),
                'idempotencyKey' => "personale-sub-{$organization->slug}",
                'clientMutationId' => "personale:subscription-{$organization->slug}",
            ]]);

        return BillingCoreLink::create([
            'organization_id' => $organization->id,
            'customer_ref' => $customer['customer']['id'],
            'contract_ref' => $contract['contract']['id'],
            'subscription_ref' => $subscription['subscription']['id'],
            'plan_version_ref' => $planVersionId,
        ]);
    }

    public static function syncSeats(Organization $organization, ?Client $client = null): void
    {
        $client ??= new Client();
        $link = self::ensureProvisioned($organization, $client);
        $quantity = self::billableSeats($organization);
        $fragments = self::problemFragments();
        $client->mutate('changeSubscription',
            "mutation(\$input: ChangeSubscriptionInput!){ changeSubscription(input: \$input){ __typename ... on ChangeSubscriptionSuccess { subscription { id currentVersion } } {$fragments} ... on IdempotencyConflict { code message } } }",
            ['input' => [
                'teamId' => $client->teamId, 'subscriptionId' => $link->subscription_ref,
                'quantity' => (string) $quantity,
                'idempotencyKey' => "personale-seats-{$organization->slug}-{$quantity}",
                'clientMutationId' => "personale:seats-{$organization->slug}",
            ]]);
    }
}
