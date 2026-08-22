<?php

namespace App\Models;

use Illuminate\Database\Eloquent\Model;
use Illuminate\Support\Str;

class Invitation extends Model
{
    protected $guarded = [];

    protected static function booted(): void
    {
        static::creating(function (Invitation $invitation) {
            $invitation->token ??= Str::random(48);
        });
    }

    public function organization()
    {
        return $this->belongsTo(Organization::class);
    }

    public function isPending(): bool
    {
        return $this->accepted_at === null && $this->revoked_at === null;
    }

    /** Single-use and email-bound, mirroring the platform semantics. */
    public function accept(User $user): Membership
    {
        if (! $this->isPending()) {
            throw new \InvalidArgumentException('invitation is not pending');
        }
        if (strtolower($user->email) !== strtolower($this->email)) {
            throw new \InvalidArgumentException('invitation was issued to a different email');
        }

        $membership = Membership::updateOrCreate(
            ['organization_id' => $this->organization_id, 'user_id' => $user->id],
            ['role' => $this->role, 'status' => 'active'],
        );
        $this->forceFill(['accepted_at' => now()])->save();

        return $membership;
    }
}
