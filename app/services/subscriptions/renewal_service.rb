# app/services/subscriptions/renewal_service.rb
# Purpose: duplicate a user's last subscription with new params.
# Usage: Subscriptions::RenewalService.new(user: user, new_params: {plan: 'Standard', duration: 6}).call
#
# Returns a Result object with:
#   success? (bool), subscription, error (string)
# Note: Does NOT create invoice - that's handled in controller after this returns

module Subscriptions
  class RenewalService
    Result = Struct.new(:success?, :subscription, :error, keyword_init: true)

    def initialize(user:, new_params: {})
      @user       = user
      @new_params = new_params
    end

    def call
      last_sub = @user.subscriptions.order(Arel.sql("COALESCE(end_date, '1900-01-01') DESC"), created_at: :desc).first
      return failure!("No previous subscription to duplicate.") unless last_sub

      new_sub = build_subscription_from(last_sub)

      ActiveRecord::Base.transaction do
        new_sub.save!

        # Copy business profile from previous subscription if it exists
        if last_sub.business_profile.present?
          BusinessProfile.create!(
            subscription: new_sub,
            business_name: last_sub.business_profile.business_name,
            vat_number: last_sub.business_profile.vat_number,
            contact_person: last_sub.business_profile.contact_person,
            street_address: last_sub.business_profile.street_address,
            suburb: last_sub.business_profile.suburb,
            postal_code: last_sub.business_profile.postal_code
          )
        end

        return success!(subscription: new_sub)
      end
    end

    private

    def success!(subscription:)
      Result.new(success?: true, subscription: subscription)
    end

    def failure!(message)
      Result.new(success?: false, error: message)
    end

    def build_subscription_from(last_sub)
      # Duplicate subscription, copying address/location info but not plan/duration/status
      duped = last_sub.dup

      # Apply new params from form (plan, duration, discount_code)
      duped.assign_attributes(@new_params.slice(:plan, :duration, :discount_code))

      # Set defaults for new subscription
      duped.assign_attributes(
        status:           "pending",
        is_paused:        false,
        is_new_customer:  false,
        start_date:       nil,  # Will be calculated in controller
        end_date:         nil,  # Don't set end_date
        collection_order: last_sub.collection_order  # Preserve collection order
      )

      duped.user = @user
      duped.customer_id ||= @user.customer_id
      duped
    end
  end
end
