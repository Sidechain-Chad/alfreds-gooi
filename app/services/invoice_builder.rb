# app/services/invoice_builder.rb
class InvoiceBuilder
  def initialize(subscription: , og: false, is_new: false, referee: nil, referred_friends: 0)
    @subscription = subscription
    @og = og
    @is_new = is_new
    @referee = referee
    @referred_friends = referred_friends
  end

  def call
    invoice = Invoice.create!(
      subscription: @subscription,
      issued_date: Time.current,
      due_date: Time.current + 2.weeks,
      total_amount: 0
    )

    add_starter_kit(invoice) if @is_new
    add_subscription_product(invoice)

    apply_referrals(invoice)
    invoice.calculate_total
    apply_discount_code(invoice) if @subscription.discount_code

    InvoiceMailer.with(invoice: invoice).invoice_created.deliver_now


    invoice
  end

  private

  def add_starter_kit(invoice)
    kit = Product.find_by(title: "#{@subscription.plan} Starter Kit")
    invoice.invoice_items.create!(product: kit, quantity: 1, amount: kit.price)
  end

  def add_subscription_product(invoice)
    title = if @og
              "#{@subscription.plan} #{@subscription.duration} month OG subscription"
            else
              "#{@subscription.plan} #{@subscription.duration} month subscription"
            end

    product = Product.find_by(title: title)
    raise "Product not found: #{title}" unless product

    invoice.invoice_items.create!(product: product, quantity: 1, amount: product.price)
  end

  def apply_referrals(invoice)
    if @referred_friends&.positive?
      discount = Product.find_by(title: "Referred a friend discount")
      invoice.invoice_items.create!(
        product: discount,
        quantity: @referred_friends,
        amount: discount.price
      )
      mark_referrals_used
    elsif @referee
      title = "Referral discount #{@subscription.plan} #{@subscription.duration} month"
      discount = Product.find_by(title: title)
      invoice.invoice_items.create!(product: discount, quantity: 1, amount: discount.price)

      Referral.create!(
        subscription: @subscription,
        referee: @subscription.user,
        referrer: @referee,
        status: :pending
      )
    end

  end

  def apply_discount_code(invoice)
    code = DiscountCode.find_by(code: @subscription.discount_code.upcase)

    if code&.available?
      if code.percentage_based?
        percent_off = code.discount_percent.clamp(0, 100)
        discount = (invoice.total_amount * percent_off / 100.0).round
        invoice.total_amount -= discount
      elsif code.fixed_amount?
        invoice.total_amount -= (code.discount_cents / 100)
      end

      invoice.total_amount = 0 if invoice.total_amount.negative?
      invoice.used_discount_code = true
      invoice.save!
      code.increment!(:used_count)
    end
  end


  def mark_referrals_used
    @subscription.user.referrals_as_referrer.completed.each(&:used!)
  end
end
