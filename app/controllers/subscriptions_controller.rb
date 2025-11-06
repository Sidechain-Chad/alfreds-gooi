class SubscriptionsController < ApplicationController
  before_action :set_subscription, only: %i[show edit update destroy want_bags pause unpause holiday_dates clear_holiday complete reassign_collections welcome welcome_invoice]
  # pretty much standard CRUD stuff
  def index
    if current_user.admin? || current_user.driver?
      @subscriptions = Subscription.active
                                    .includes(:user, :invoices)  # Preloads users to avoid N+1 queries
                                    .order_by_user_name

    else
      @subscriptions = Subscription.where(user_id: current_user.id)
    end
  end

  def pending
    if current_user.admin? || current_user.driver?
      @subscriptions = Subscription.pending
                             .includes(:user, :invoices)  # Preloads users to avoid N+1 queries
                             .order_by_user_name
    else
      @subscriptions = Subscription.pending
                              .where(user_id: current_user.id)
    end
  end

  def all
    if current_user.admin? || current_user.driver?
      @subscriptions = Subscription.active
                             .includes(:user, :invoices)  # Preloads users to avoid N+1 queries
                             .order_by_user_name
    else
      @subscriptions = Subscription.active
                              .where(user_id: current_user.id)
    end
  end

  def completed
    if current_user.admin? || current_user.driver?
      @subscriptions = Subscription.completed
                             .includes(:user, :invoices)  # Preloads users to avoid N+1 queries
                             .order_by_user_name
    else
      @subscriptions = Subscription.completed
                              .where(user_id: current_user.id)
    end
  end

  def legacy
    if current_user.admin? || current_user.driver?
      @subscriptions = Subscription.legacy
                             .includes(:user, :invoices)  # Preloads users to avoid N+1 queries
                             .order_by_user_name
    else
      @subscriptions = Subscription.legacy
                              .where(user_id: current_user.id)
    end
  end

  def paused
    if current_user.admin? || current_user.driver?
      @subscriptions = Subscription.paused
                             .includes(:user, :invoices)  # Preloads users to avoid N+1 queries
                             .order_by_user_name
    else
      @subscriptions = Subscription.paused
                              .where(user_id: current_user.id)
    end
  end

  def show
    @subscription = Subscription.joins(:user).find(params[:id])
    @next_subscription = @subscription.user.subscriptions.last if @subscription.completed?
    @collections = @subscription.collections
    @total_collections = @subscription.total_collections
    @skipped_collections = @subscription.skipped_collections
    @successful_collections = @total_collections - @skipped_collections
    @total_bags = @subscription.total_bags
    @total_buckets = @subscription.total_buckets
    @bags_last_month = @subscription.total_bags_last_n_months(1)
    @bags_last_three_months = @subscription.total_bags_last_n_months(3)
    @bags_last_six_months = @subscription.total_bags_last_n_months(6)
    @buckets_last_month = @subscription.total_buckets_last_n_months(1).to_i
    @buckets_last_three_months = @subscription.total_buckets_last_n_months(3).to_i
    @buckets_last_six_months = @subscription.total_buckets_last_n_months(6).to_i
    scope = @subscription.collections
                       .where(skip: false)
                       .where.not(updated_at: nil, time: nil)
                       # average seconds past local midnight in Africa/Johannesburg
    avg_secs = scope.where.not(time: nil)
                    .average(Arel.sql(
                      "EXTRACT(EPOCH FROM ((time AT TIME ZONE 'Africa/Johannesburg') - DATE_TRUNC('day', (time AT TIME ZONE 'Africa/Johannesburg'))))"
                    )).to_f

    @avg_time_sample     = scope.where.not(time: nil).count
    @avg_collection_time = @avg_time_sample.positive? ? (Time.zone.now.beginning_of_day + avg_secs).strftime('%H:%M') : nil
  end

  def new
    @subscription = Subscription.new
  end

  def create
    # Use RenewalService to duplicate last subscription with new params
    result = Subscriptions::RenewalService.new(
      user: current_user,
      new_params: subscription_params
    ).call

    if result.success?
      @subscription = result.subscription

      # Calculate referred friends for invoice builder
      referred_friends = current_user.referrals_as_referrer.where(status: 'completed').count

      # Create invoice AFTER subscription has correct plan/duration
      @invoice = InvoiceBuilder.new(
        subscription: @subscription,
        og: current_user.og,
        is_new: false,
        referee: nil,
        referred_friends: referred_friends
      ).call

      # check for sub overlap and set proper start date
      start_date = @subscription.suggested_start_date(payment_date: Date.current)
      @subscription.update!(start_date: start_date)

      # check if future collections exist and move them to this sub
      @subscription.adopt_future_collections!

      # # check if the user wants bags
      # redirect_to want_bags_subscription_path(@subscription)

      flash.now[:notice] = "Your subscription has been created and will be active once payment is made."
      redirect_to invoice_path(@invoice)
    else
      flash[:alert] = result.error
      @subscription = Subscription.new(subscription_params)
      render :new, status: :unprocessable_entity
    end
  end

  def want_bags
    # @invoice = create_invoice_for_subscription(@subscription, current_user.og, false)
    @invoice = @subscription.invoices.order(created_at: :asc).last
    @compost_bags = Product.find_by(title: "Compost bin bags")
    @soil_bags = Product.find_by(title: "Soil for Life Compost")
    flash.now[:notice] = "Your subscription has been created and will be active once payment is made."
  end

  def edit
    # @subscription = Subscription.find(params[:id])
  end

  def update
    # subscription = Subscription.find(params[:id])
    # user = subscription.user
    if @subscription.update(subscription_params)
      @subscription.collections
                 .where(date: @subscription.holiday_start..@subscription.holiday_end)
                 .find_each { |c| c.mark_skipped!(by: current_user, reason: "holiday_range") }

      if @subscription.completed? && @subscription.end_date.nil?
        @subscription.end_date!
      end
      if @subscription.user == current_user
        if subscription_params[:street_address].present?
          @subscription.set_collection_day
          redirect_to manage_path, notice: "Updated, your collection day is now #{@subscription.collection_day}"
        else
          redirect_to manage_path, notice: "Subscription updated."
        end

      else
        redirect_to subscription_path(@subscription)
      end
    else
      render :edit, status: :unprocessable_entity
    end

  end

  def collections
    @subscription = Subscription.find(params[:id])
    @collections = @subscription.collections.order(date: :desc)
  end

  def complete
    # @subscription = Subscription.find(params[:id])
    @subscription.completed!
    if @subscription.start_date
      end_date = @subscription.start_date + @subscription.duration.months
    else
      @subscription.update(start_date: @subscription.created_at.to_date)
      end_date = @subscription.start_date + @subscription.duration.months
    end

    if @subscription.update!(end_date: end_date)
      redirect_to subscription_path(@subscription), notice: "#{@subscription.user.first_name}'s subscription marked complete"
    else
      redirect_to subscription_path(@subscription), notice: "Error marking #{@subscription.user.first_name}'s subscription complete"
    end
  end

  def reassign_collections
    subscription = Subscription.find(params[:id])
    dry_run = params[:dry_run].to_s == "1"

    result = subscription.reassign_user_collections!(dry_run: dry_run)

    if result[:next_sub_id].nil?
      redirect_to admin_user_path(subscription.user), alert: "No next subscription found after this one; nothing to reassign."
      return
    end

    msg =
      if dry_run
        "Dry-run: would move #{result[:to_move_ids].size} collections to sub ##{result[:next_sub_id]} from #{result[:boundary]} onward."
      else
        "Reassigned #{result[:updated_total]} collections to sub ##{result[:next_sub_id]} from #{result[:boundary]} onward."
      end

    redirect_to admin_user_path(subscription.user), notice: msg
  rescue => e
    redirect_to admin_user_path(subscription.user), alert: "Reassign error: #{e.class} #{e.message}"
  end

  def welcome
    @subscription = Subscription.find(params[:id])
    @discount_code = DiscountCode.find_by(code: @subscription.discount_code&.upcase)

    if @discount_code.present?
      discount_amount = nil
      if @discount_code.discount_cents.present?
        @discount_amount = @discount_code.discount_cents / 100.0
      elsif @discount_code.discount_percent.present?

        title = "#{@subscription.plan} #{@subscription.duration} month subscription"
        product = Product.find_by(title: title)
        if product
          @discount_amount = (product.price * @discount_code.discount_percent / 100.0).round(2)
        end
      end
    end
  end

  def welcome_invoice
    @subscription = Subscription.find(params[:id])
    @discount_code = DiscountCode.find_by(code: @subscription.discount_code&.upcase)


    # Rails.logger.info "Set users referral code to: #{current_user.generate_referral_code}"
    is_new = params[:new] == "true"

    # referal code of the referrer (so you kInnow who referred them)
    referral_code = @subscription.referral_code
    # find the referee by the referral code
    referee = User.find_by(referral_code: referral_code)

    if @subscription.invoices.empty?
      @invoice = InvoiceBuilder.new(
        subscription: @subscription,
        og: nil,
        is_new: is_new,
        referee: referee
      ).call

    end
    @invoice = @subscription.invoices.order(created_at: :asc).last
    redirect_to invoice_path(@invoice)
  end

  def pause
    @subscription = Subscription.find(params[:id])
    next_collection = @subscription.collections.where("date >= ?", Date.today).order(:date).first
    if next_collection
      next_collection.update!(skip: true)
      redirect_to manage_path, notice: "Collection schedule updated"
    else
      redirect_to manage_path, notice: "Something went wrong, please try again or contact us for help"
    end
  end

  def unpause
    @subscription = Subscription.find_by(id: params[:id])

    if @subscription.nil?
      redirect_to manage_path, alert: "Subscription not found"
      return
    end

    next_collection = @subscription.collections.where("date >= ?", Date.today).order(:date).first

    if next_collection
      if next_collection.update!(skip: false)
        @subscription.update!(is_paused: false)
        redirect_to manage_path, notice: "Collection schedule updated successfully"
      else
        Rails.logger.error "Failed to update next collection: #{next_collection.errors.full_messages.join(', ')}"
        redirect_to manage_path, alert: "Failed to update the collection schedule. Please try again or contact support."
      end
    else
      if @subscription.update(is_paused: true)
        @subscription.update!(is_paused: false)
        redirect_to manage_path, notice: "Subscription unpaused successfully"
      else
        Rails.logger.error "Failed to unpause subscription: #{subscription.errors.full_messages.join(', ')}"
        redirect_to manage_path, alert: "Something went wrong while unpausing the subscription. Please try again or contact support."
      end
    end
  end

  def holiday_dates
    @subscription = Subscription.find(params[:id])
    if @subscription.update(subscription_params)
      if @subscription.holiday_start && @subscription.holiday_end
        @subscription.collections
                     .where(date: @subscription.holiday_start..@subscription.holiday_end)
                     .update_all(skip: true)
      end
      redirect_to manage_path, notice: "Holiday set!"
    else
      redirect_to manage_path, status: :unprocessable_entity
    end
  end

  # set holiday start and end to nil to clear holiday
  def clear_holiday
    @subscription = Subscription.find(params[:id])
    if @subscription.update(holiday_start: nil, holiday_end: nil)
      @subscription.collections
             .where('date >= ?', Date.current)
             .update_all(skip: false)
      redirect_to manage_path, notice: "Holiday Canceled!"
    else
      redirect_to manage_path, status: :unprocessable_entity
    end
  end

  # a special view that will load all of the collections for a given day
  def today
    # in production today will be the current day,
    # today = "Wednesday"
    # PRODUCTION
    today = Date.today
    # but in testing I want to be able to test the view for a given day
    # DEVELOPMENT
    # today = Date.today  + 1
    @today = today.strftime("%A")

    driver = User.find_by(first_name: "Alfred")
    @drivers_day = DriversDay.find_or_create_by!(date: today, user_id: driver.id)

    # Fetch subscriptions for the day and eager load related collections (thanks chat)
    # @subscriptions = Subscription.active_subs_for(@today)
    # @collections = @drivers_day.collections.includes(:subscription, :user).order(:position)

    collections = @drivers_day.collections
                .includes(:subscription, :user)
                .joins(:subscription)
                .order('subscriptions.collection_order')
                .each_with_index do |collection, index|
                  collection.update(position: index + 1) # Set position starting from 1
                end
    drop_off_events = @drivers_day.drop_off_events.includes(:drop_off_site).order(:position)

    # Combine collections and drop-off events, sorted by position
    @route_items = (collections.to_a + drop_off_events.to_a).sort_by(&:position)
  end

  def recently_lapsed
    # Find driver's day
    today = Date.today
    driver = User.find_by(first_name: "Alfred", role: 'driver')
    @drivers_day = DriversDay.find_or_create_by!(date: today, user_id: driver.id)

    two_weeks_ago = today - 2.weeks

    # Get IDs of subs already on today's list
    existing_ids = @drivers_day.collections.pluck(:subscription_id)

    # Find recently completed subscriptions for today's collection day
    @recently_lapsed = Subscription
      .where(collection_day: Date::DAYNAMES[today.wday])  # Matches today (enum uses day name string)
      .where(status: 'completed')                          # Properly ended
      .where(end_date: two_weeks_ago..today)           # Ended in last 2 weeks
      .where.not(id: existing_ids)                     # Not already on list
      .includes(:user, :collections)
      .order(end_date: :desc)                          # Most recent first

    # Filter to only those who actually had collections in their last week
    @recently_lapsed = @recently_lapsed.select do |sub|
      last_week = sub.end_date - 1.week
      sub.collections.where('date >= ? AND date <= ?', last_week, sub.end_date).where(skip: false).any?
    end
  end

  def collect_courtesy
    subscription = Subscription.find(params[:id])
    today = Date.today
    driver = User.find_by(first_name: "Alfred", role: 'driver')
    @drivers_day = DriversDay.find_or_create_by!(date: today, user_id: driver.id)

    # Create collection for today
    Collection.create!(
      subscription: subscription,
      drivers_day: @drivers_day,
      date: today,
      bags: 0,
      skip: false,
      new_customer: false,
      buckets: 0.0
    )

    user = subscription.user
    flash[:notice] = "#{user.first_name} added to today's collections!"
    redirect_to recently_lapsed_subscriptions_path
  end

  # a special view that will load all of the collections for a given day
  def today_notes
    # in production today will be the current day,
    # today = "Wednesday"
    # PRODUCTION
    today = Date.today
    # but in testing I want to be able to test the view for a given day
    # DEVELOPMENT
    # today = Date.today  + 1
    @today = today.strftime("%A")
    @drivers_day = DriversDay.find_or_create_by(date: today)
    # Fetch subscriptions for the day and eager load related collections (thanks chat)
    @subscriptions = Subscription.active_subs_for(@today)
  end

  def import_csv
    uploaded_file = params[:subscription][:file]
      # loop through the file and update subscriptions for each row
      CSV.foreach(uploaded_file.path, headers: :first_row) do |row|
        # Process the subscription
        subscription = process_subscription(row)
        puts subscription.end_date if subscription
      end
    redirect_to subscriptions_path, notice: "Subscriptions updated"
  end

  def update_end_date
  end

  def export
    @subscriptions = Subscription.all
    send_data generate_csv(@subscriptions),
            filename: "subscriptions_#{Date.today}.csv",
            type: "text/csv"
    # generate_csv(@subscriptions, "subscriptions_#{Date.today}.csv")

    # redirect_to subscriptions_path, notice: "Subscription data exported"
  end

  private

  def subscription_params
    params.require(:subscription).permit(:customer_id, :access_code, :apartment_unit_number, :street_address, :suburb, :duration, :start_date,
                  :collection_day, :plan, :status, :is_paused, :user_id, :holiday_start, :holiday_end, :collection_order, :referral_code, :discount_code,
                  user_attributes: [:id, :first_name, :last_name, :phone_number, :email])
  end

  def set_subscription
    @subscription = Subscription.find(params[:id])
  end

  def process_subscription(row)
    subscription = Subscription.find_by(customer_id: row['customer_id'])
    if subscription
      is_paused = row['status'] == 'paused'
      start_date = row['start_date'].present? ? DateTime.parse(row['start_date']) : nil

      if subscription.update!(is_paused: is_paused,
                              start_date: start_date)
        puts "Subscription updated for #{subscription.user.first_name}"
      else
        puts "Failed to update subscription for #{subscription.user.first_name}: #{subscription.errors.full_messages.join(", ")}"
      end
    # puts subscription.collection_day
    subscription
    else
      puts "Subscription not found for customer_id: #{row['customer_id']}"
      nil
    end
  end

  def generate_csv(subscriptions)
    CSV.generate(headers: true) do |csv|
      csv << ["customer_id", "first_name", "email", "suburb", "plan", "duration", "start_date", "end_date", "total_collections", "status"] # Headers

      subscriptions.each do |subscription|
        csv << [
          subscription.customer_id,
          subscription.user.first_name,
          subscription.user.email,
          subscription.suburb,
          subscription.plan,
          subscription.duration,
          subscription.start_date&.to_date,
          subscription.end_date,
          subscription.total_collections,
          subscription.is_paused ? "paused" : "active"
        ]
      end
    end
  end


  # def create_invoice_for_subscription(subscription, og, is_new, referee, referred_friends)
  #   # create an invoice that belongs to the subscriber
  #   invoice = Invoice.create!(
  #     subscription: subscription,
  #     issued_date: Time.current,
  #     due_date: Time.current + 2.week,
  #     total_amount: 0
  #   )
  #   # if new customer add a starter kit
  #   if is_new
  #       starter_kit = Product.find_by(title: "#{subscription.plan} Starter Kit")
  #       invoice.invoice_items.create!(
  #         product: starter_kit,
  #         quantity: 1,
  #         amount: starter_kit.price
  #       )
  #     end
  #   # Add the correct subscription product to the invoice
  #   if og
  #     product = Product.find_by(title: "#{subscription.plan} #{subscription.duration} month OG subscription")
  #     invoice.invoice_items.create!(
  #       product: product,
  #       quantity: 1,
  #       amount: product.price
  #     )
  #   else
  #     product = Product.find_by(title: "#{subscription.plan} #{subscription.duration} month subscription")

  #     invoice.invoice_items.create!(
  #       product: product,
  #       quantity: 1,
  #       amount: product.price
  #     )
  #   end
  #   raise "Product not found" unless product

  #   # if they haven't got a referral code they may be a referrer, check if anyone has used their referral code and assign as many discounts as successful referrals

  #   if referred_friends
  #     if referred_friends >= 1
  #       referee_discount = Product.find_by(title: "Referred a friend discount")
  #       invoice.invoice_items.create!(
  #         product: referee_discount,
  #         quantity: referred_friends,
  #         amount: referee_discount.price
  #       )
  #     end
  #     completed_referrals = current_user.referrals_as_referrer.completed
  #     completed_referrals.each do |referral|
  #       referral.used!
  #     end
  #   # if the subscriber has a referral code, give them a discount
  #   elsif referee
  #     discount_item = Product.find_by(title: "Referral discount #{subscription.Standard? ? subscription.plan.downcase : subscription.plan.upcase} #{subscription.duration} month")
  #     invoice.invoice_items.create!(
  #       product: discount_item,
  #       quantity: 1,
  #       amount: discount_item.price
  #     )
  #     # create a referral for the person who referred them
  #     referral = Referral.new
  #     referral.subscription = subscription
  #     referral.referee = current_user
  #     referral.referrer = referee
  #     referral.save!
  #     puts "referral created with id #{referral.id}"
  #   end
  #   invoice.calculate_total
  #   invoice
  # end
end
