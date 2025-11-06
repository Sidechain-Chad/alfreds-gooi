# frozen_string_literal: true

class Users::RegistrationsController < Devise::RegistrationsController
  before_action :configure_sign_up_params, only: [:create, :new]
  # before_action :configure_account_update_params, only: [:update]

  # GET /resource/sign_up
  def new
    @plan = params[:plan]
    @duration = params[:duration]
    @discount_code = params[:discount_code] if params[:discount_code].present?
    @referral_code = params[:referral] if params[:referral].present?


    # Always build a fresh resource, Devise might hang onto state between requests
    self.resource = build_resource({})
    resource.subscriptions.clear

    resource.subscriptions.new(
      plan: @plan,
      duration: @duration,
      discount_code: @discount_code,
      referral_code: @referral_code,
      is_paused: true
    )

    respond_with resource
  end



  # POST /resource
  def create

    build_resource(sign_up_params)

    if resource.save
      if resource.active_for_authentication?
        sign_up(resource_name, resource)
        respond_with resource, location: after_sign_up_path_for(resource)
      else
        expire_data_after_sign_in!
        respond_with resource, location: after_inactive_sign_up_path_for(resource)
      end
    else
      clean_up_passwords resource
      set_minimum_password_length
      respond_with resource
    end

    Rails.logger.debug "🧪 Subscriptions count: #{resource.subscriptions.size}"

  end

  # GET /resource/edit
  # def edit
  #   super
  # end

  # PUT /resource
  # def update
  #   super
  # end

  # DELETE /resource
  # def destroy
  #   super
  # end

  # GET /resource/cancel
  # Forces the session data which is usually expired after sign
  # in to be expired now. This is useful if the user wants to
  # cancel oauth signing in/up in the middle of the process,
  # removing all OAuth session data.
  # def cancel
  #   super
  # end

  # protected

  # If you have extra params to permit, append them to the sanitizer.
  # def configure_sign_up_params
  #   devise_parameter_sanitizer.permit(:sign_up, keys: [:attribute])
  # end

  # If you have extra params to permit, append them to the sanitizer.
  # def configure_account_update_params
  #   devise_parameter_sanitizer.permit(:account_update, keys: [:attribute])
  # end

  # The path used after sign up.
  # def after_sign_up_path_for(resource)
  #   super(resource)
  # end

  # The path used after sign up for inactive accounts.
  # def after_inactive_sign_up_path_for(resource)
  #   super(resource)
  # end

  protected

  def configure_sign_up_params
    devise_parameter_sanitizer.permit(:sign_up, keys: [
      :first_name, :last_name, :email, :phone_number, :password, :password_confirmation,
      subscriptions_attributes: [
        :plan, :duration, :street_address, :suburb, :referral_code,
        :discount_code, :apartment_unit_number, :is_paused
      ]
    ])
  end



  # def after_sign_up_path_for(resource)
  #   if resource.persisted?
  #     @subscription = Subscription.create!(
          # user_id: resource.id,
          # plan: params[:user][:subscription][:plan],
          # duration: params[:user][:subscription][:duration],
          # street_address: params[:user][:subscription][:street_address],
          # suburb: params[:user][:subscription][:suburb],
          # is_new_customer: true)
  #     if @subscription
  #       UserMailer.with(subscription: @subscription).welcome.deliver_now
  #       UserMailer.with(subscription: @subscription).sign_up_alert.deliver_now
  #       welcome_subscription_path(@subscription)
  #     else
  #       redirect_to new_user_registration_path(plan: params[:user][:subscription][:plan], duration: params[:user][:subscription][:duration], street_address: params[:user][:subscription][:street_address], suburb: params[:user][:subscription][:suburb])
  #     end
  #   else
  #     redirect_to new_user_registration_path(plan: params[:user][:subscription][:plan], duration: params[:user][:subscription][:duration], street_address: params[:user][:subscription][:street_address], suburb: params[:user][:subscription][:suburb])
  #   end]
  #   # resource.create_initial_invoice
  #   # subscription = resource.subscriptions.first
  #   # invoice = subscription.invoices.first``
  # end

  def after_sign_up_path_for(resource)
    subscription = resource.subscriptions.first

    if subscription.present?
      # Apply valid discount code
      # if subscription.discount_code.present?
      #   code = DiscountCode.find_by(code: subscription.discount_code.to_s.strip.upcase)

      #   if code&.available?
      #     subscription.update!(discount_code: code)
      #   end
      # end

      # Send emails
      UserMailer.with(subscription: subscription).welcome.deliver_now
      UserMailer.with(subscription: subscription).sign_up_alert.deliver_now

      welcome_subscription_path(subscription)
    else
      Rails.logger.error "No subscription found for user #{resource.id} after signup"
      root_path
    end
  end



end
