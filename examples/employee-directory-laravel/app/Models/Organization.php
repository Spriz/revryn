<?php

namespace App\Models;

use Illuminate\Database\Eloquent\Model;

class Organization extends Model
{
    protected $guarded = [];

    public function memberships()
    {
        return $this->hasMany(Membership::class);
    }

    public function employees()
    {
        return $this->hasMany(Employee::class);
    }

    public function departments()
    {
        return $this->hasMany(Department::class);
    }

    public function locations()
    {
        return $this->hasMany(Location::class);
    }

    public function customFieldDefs()
    {
        return $this->hasMany(CustomFieldDef::class);
    }

    public function onboardingTasks()
    {
        return $this->hasMany(OnboardingTask::class)->orderBy('position');
    }

    public function invitations()
    {
        return $this->hasMany(Invitation::class);
    }

    public function changeLogs()
    {
        return $this->hasMany(ChangeLog::class)->latest();
    }

    public function roleOf(User $user): ?string
    {
        return $this->memberships()
            ->where('user_id', $user->id)->where('status', 'active')
            ->value('role');
    }

    public function activeEmployees(): int
    {
        return $this->employees()->where('status', 'active')->count();
    }

    public function log(?User $actor, string $verb, string $summary): void
    {
        $this->changeLogs()->create([
            'actor_id' => $actor?->id,
            'verb' => $verb,
            'summary' => $summary,
        ]);
    }
}
