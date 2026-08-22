<?php

namespace App\Models;

use Illuminate\Database\Eloquent\Model;

class Employee extends Model
{
    protected $guarded = [];
    protected $casts = ['custom_fields' => 'array', 'started_on' => 'date'];

    protected static function booted(): void
    {
        // Integrated mode: hires/offboardings flow to Billing Core as the
        // billable-seat quantity; failures log and never break the action.
        $sync = function (Employee $employee) {
            if (! \App\BillingCore\Integration::enabled()) {
                return;
            }
            try {
                \App\BillingCore\Provisioning::syncSeats($employee->organization);
            } catch (\App\BillingCore\BillingCoreError $error) {
                logger()->error("billing seat sync failed: {$error->getMessage()}");
            }
        };
        static::created($sync);
        static::updated($sync);
    }

    public function organization()
    {
        return $this->belongsTo(Organization::class);
    }

    public function department()
    {
        return $this->belongsTo(Department::class);
    }

    public function location()
    {
        return $this->belongsTo(Location::class);
    }

    public function manager()
    {
        return $this->belongsTo(Employee::class, 'manager_id');
    }

    public function reports()
    {
        return $this->hasMany(Employee::class, 'manager_id');
    }

    public function onboardingItems()
    {
        return $this->hasMany(EmployeeOnboardingItem::class);
    }
}
