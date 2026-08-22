<?php

use App\Http\Controllers\AuthController;
use App\Http\Controllers\BillingController;
use App\Http\Controllers\DirectoryConfigController;
use App\Http\Controllers\EmployeeController;
use App\Http\Controllers\MembershipController;
use App\Http\Controllers\OrganizationController;
use Illuminate\Support\Facades\Route;

Route::get('/register', [AuthController::class, 'showRegister']);
Route::post('/register', [AuthController::class, 'register']);
Route::get('/login', [AuthController::class, 'showLogin'])->name('login');
Route::post('/login', [AuthController::class, 'login']);
Route::post('/logout', [AuthController::class, 'logout']);

Route::middleware('auth')->group(function () {
    Route::get('/', [OrganizationController::class, 'index']);
    Route::get('/orgs/new', [OrganizationController::class, 'create']);
    Route::post('/orgs', [OrganizationController::class, 'store']);
    Route::get('/orgs/{slug}', [OrganizationController::class, 'show']);

    Route::get('/orgs/{slug}/members', [MembershipController::class, 'index']);
    Route::patch('/orgs/{slug}/members/{membershipId}', [MembershipController::class, 'update']);
    Route::delete('/orgs/{slug}/members/{membershipId}', [MembershipController::class, 'destroy']);
    Route::post('/orgs/{slug}/invitations', [MembershipController::class, 'invite']);
    Route::post('/orgs/{slug}/invitations/{invitationId}/revoke', [MembershipController::class, 'revokeInvitation']);
    Route::get('/invitations/{token}', [MembershipController::class, 'showInvitation']);
    Route::post('/invitations/{token}', [MembershipController::class, 'acceptInvitation']);

    Route::get('/orgs/{slug}/employees', [EmployeeController::class, 'index']);
    Route::post('/orgs/{slug}/employees', [EmployeeController::class, 'store']);
    Route::get('/orgs/{slug}/employees.csv', [EmployeeController::class, 'exportCsv']);
    Route::post('/orgs/{slug}/employees/import', [EmployeeController::class, 'importCsv']);
    Route::get('/orgs/{slug}/employees/{employeeId}', [EmployeeController::class, 'show']);
    Route::patch('/orgs/{slug}/employees/{employeeId}', [EmployeeController::class, 'update']);
    Route::post('/orgs/{slug}/employees/{employeeId}/offboard', [EmployeeController::class, 'offboard']);
    Route::post('/orgs/{slug}/employees/{employeeId}/onboarding/{itemId}', [EmployeeController::class, 'toggleOnboarding']);

    Route::post('/orgs/{slug}/departments', [DirectoryConfigController::class, 'storeDepartment']);
    Route::post('/orgs/{slug}/locations', [DirectoryConfigController::class, 'storeLocation']);
    Route::post('/orgs/{slug}/custom-fields', [DirectoryConfigController::class, 'storeCustomField']);
    Route::post('/orgs/{slug}/onboarding-tasks', [DirectoryConfigController::class, 'storeOnboardingTask']);
    Route::get('/orgs/{slug}/changelog', [DirectoryConfigController::class, 'changeLog']);

    Route::get('/orgs/{slug}/billing', [BillingController::class, 'show']);
    Route::patch('/orgs/{slug}/billing', [BillingController::class, 'update']);
});
