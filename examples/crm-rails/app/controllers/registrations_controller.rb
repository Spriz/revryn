class RegistrationsController < ApplicationController
  def new; end

  def create
    user = User.new(
      email: params[:email], full_name: params[:full_name],
      password: params[:password], password_confirmation: params[:password]
    )
    if params[:password].to_s.length >= 8 && user.save
      session[:user_id] = user.id
      redirect_to root_path
    else
      flash.now[:alert] = "Email and a password of at least 8 characters are required."
      render :new, status: :unprocessable_entity
    end
  end
end
