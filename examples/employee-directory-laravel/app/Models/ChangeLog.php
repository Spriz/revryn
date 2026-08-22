<?php

namespace App\Models;

use Illuminate\Database\Eloquent\Model;

class ChangeLog extends Model
{
    protected $guarded = [];

    public function actor()
    {
        return $this->belongsTo(User::class, 'actor_id');
    }
}
