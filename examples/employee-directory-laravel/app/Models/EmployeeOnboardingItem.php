<?php

namespace App\Models;

use Illuminate\Database\Eloquent\Model;

class EmployeeOnboardingItem extends Model
{
    protected $guarded = [];
    protected $casts = ['completed_at' => 'datetime'];

    public function task()
    {
        return $this->belongsTo(OnboardingTask::class, 'onboarding_task_id');
    }
}
