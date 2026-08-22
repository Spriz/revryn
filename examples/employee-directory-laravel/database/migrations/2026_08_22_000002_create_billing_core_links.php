<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    public function up(): void
    {
        Schema::create('billing_core_links', function (Blueprint $table) {
            $table->id();
            $table->foreignId('organization_id')->unique()->constrained()->cascadeOnDelete();
            $table->string('customer_ref');
            $table->string('contract_ref');
            $table->string('subscription_ref');
            $table->string('plan_version_ref');
            $table->timestamps();
        });
    }

    public function down(): void
    {
        Schema::dropIfExists('billing_core_links');
    }
};
