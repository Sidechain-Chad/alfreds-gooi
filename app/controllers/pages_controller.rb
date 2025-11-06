class PagesController < ApplicationController
  skip_before_action :authenticate_user!, only: [ :home, :story ]

  def home
    @discount_code = params[:discount_code]
    @interest = Interest.new
    if @discount_code.present?
      found_code = DiscountCode.find_by(code: @discount_code.upcase)
      if found_code.discount_cents.present?
        @discount_amount = (found_code.discount_cents / 100.0)
      elsif found_code.discount_percent.present?
        @discount_percent = found_code.discount_percent.to_f / 100.0
      end
    end
    @pct = (@discount_percent || 0.0).to_f
    @amt = (@discount_amount || 0.0).to_f
    @referral_code = params[:referral]
  end

  def today
    today = Date.today
    # but in testing I want to be able to test the view for a given day
    # DEVELOPMENT
    # today = Date.today  + 1
    @today = today.strftime("%A")
    @drivers_day = DriversDay.find_or_create_by(date: today)
    # Fetch subscriptions for the day and eager load related collections (thanks chat)
    # @subscriptions = Subscription.active_subs_for(@today)
    @collections = @drivers_day.collections.includes(:subscription, :user).order(:order)
    @collections.joins(:subscription)
                .order('subscriptions.collection_order')
                .each_with_index do |collection, index|
                  collection.update(position: index + 1) # Set position starting from 1
                end
  end

    def story
  end

  private

  def fetch_snapscan_payments(merchant_reference)
    # Example: Replace with actual SnapScan API fetch logic
    api_key = ENV['SNAPSCAN_API_KEY']
    service = Snapscan::ApiClient.new(api_key)
    payments = service.fetch_payments
    payments.select { |payment| payment["merchantReference"] == merchant_reference }
  end

  def handle_successful_payment(successful_payment)
    # Find the user and subscription by merchant reference
    subscription = Subscription.find_by(customer_id: successful_payment["merchantReference"])
    return unless subscription
    last_invoice = @subscription.invoices.order(created_at: :desc).first
    # Update subscription and mark the last invoice as paid
    if last_invoice && last_invoice.total_amount.to_i == successful_payment["totalAmount"].to_i
      last_invoice.update!(paid: true)
      subscription.update!(status: 'active', start_date: subscription.suggested_start_date)
    end
  end

end
