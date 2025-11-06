class InvoicesController < ApplicationController
  before_action :set_invoice, only: %i[show edit update destroy paid issued_bags send]

  def index
    if current_user.admin?
      @invoices = Invoice.includes(subscription: :user).order(issued_date: :desc)
    elsif current_user.customer?
      @invoices = current_user.invoices.includes(subscription: :user).order(issued_date: :desc)
    end
  end

  def new
    @invoice = Invoice.new
    @products = Product.all
    @invoice.invoice_items.build
  end

  def create
    @invoice = Invoice.new
    @invoice.subscription = Subscription.find(params[:invoice][:subscription_id])
    @invoice.save!
    if @invoice.update(issued_date: Time.current, due_date: Time.current + 1.week)

      create_invoice_items(@invoice)
      @invoice.calculate_total
      redirect_to invoice_path(@invoice), notice: 'Invoice was successfully created.'
    else
      @products = Product.all # Re-fetch products in case of validation errors
      render :new, status: :unprocessable_entity
    end
  end

  def edit
    @products = Product.all
    @invoice.invoice_items.build if @invoice.invoice_items.empty?
  end

  def update
    if params[:invoice][:invoice_items_attributes].present?
      # Handle updates and deletions via nested attributes
      @invoice.update(invoice_params)

      # Handle new items manually
      params[:invoice][:invoice_items_attributes].each do |key, item_params|
        next unless key.to_s.start_with?('new_')
        next if item_params[:quantity].blank? || item_params[:quantity].to_f <= 0

        product = Product.find(item_params[:product_id])
        @invoice.invoice_items.create!(
          product_id: product.id,
          quantity: item_params[:quantity].to_f,
          amount: product.price
        )
      end

      @invoice.calculate_total
      @subscription = @invoice.subscription
      redirect_to invoice_path(@invoice), notice: 'Invoice was successfully updated.'
    else
      # Legacy behavior for issued_bags route
      create_invoice_items(@invoice)
      redirect_to invoice_path(@invoice)
    end
  end

  def show
    # @invoice = Invoice.find(params[:id])
    @subscription = @invoice.subscription
    @referrer_discount = Product.find_by(title: "Referred a friend discount")
    @discount_code = DiscountCode.find_by(code: @subscription.discount_code&.upcase) if @invoice.used_discount_code?
  end

  def destroy
    # @invoice = Invoice.find(params[:id])
    @invoice.destroy
    redirect_to invoices_path
  end

  def bags
    @subscription = current_user.subscriptions.last
    @invoice = Invoice.create(issued_date: Time.current, due_date: Time.current + 1.week, total_amount: 0, subscription_id: @subscription.id)
    bags = params[:bags].to_i
    product = Product.find_by(title: "Compost bin bags")
    @invoice.invoice_items.create!(
      product_id: product.id,
      quantity: bags,
      amount: product.price
    )
    @invoice.calculate_total
  end

  def paid
    # @invoice = Invoice.find(params[:id])
    if @invoice.update!(paid: true)
      subscription = @invoice.subscription
      subscription.active!
      subscription.update(start_date: subscription.suggested_start_date)

      redirect_to invoice_path(@invoice)
    else
      render :show, status: "An error occured the invoice is #{@invoice.paid ? 'paid' : 'not paid' }"
    end
  end

  def issued_bags
    @subscription = @invoice.subscription
    create_invoice_items(@invoice)
    @invoice.save!
    redirect_to send_invoice_path(@invoice)
  end


  private

  def invoice_params
    params.require(:invoice).permit(
      :issued_date,
      :due_date,
      :subscription_id,
      invoice_items_attributes: [:id, :product_id, :quantity, :amount, :_destroy]
    )
  end

  def invoice_items_params
    # params.require(:invoice).permit(:issued_date, :due_date, :subscription_id)
    params.require(:invoice).permit(invoice_items_attributes: [ :id, :product_id, :quantity ])
  end

  def set_invoice
    @invoice = Invoice.find(params[:id])
  end

  def create_invoice_items(invoice)
    invoice_items_params[:invoice_items_attributes].each do |product_hash|
      if product_hash.class == Array
        product = Product.find(product_hash[1]["product_id"].to_i)
        quantity = product_hash[1]["quantity"].to_f
      else
        product = Product.find(product_hash[:product_id].to_i)
        quantity = product_hash[:quantity].to_f
      end
      next if quantity.blank? || quantity <= 0

      invoice.invoice_items.create!(
        product_id: product.id,
        quantity: quantity,
        amount: product.price
      )
    end
    invoice.calculate_total

  end
end
