# name: discourse-login-helper
# about: shorten process of loging in by email
# version: 0.3
# authors: Thomas Kalka
# url: https://github.com/thoka/discourse-login-helper
# frozen_string_literal: true

enabled_site_setting :login_helper_enabled
PLUGIN_NAME ||= "login-helper".freeze

after_initialize do
  # if username is provided in url, we redirect to login page directly providing the username in cookies

  # test: http://localhost:4200/t/weiteres-geheimes-thema/68?email=thomas.kalka@gmail.com
  #

  module ::LoginHelper
    class Engine < ::Rails::Engine
      engine_name PLUGIN_NAME
      isolate_namespace LoginHelper
    end
  end

  ::LoginHelper::Engine.routes.draw { get "/" => "login_helper#send_login_mail" }
  ::Discourse::Application.routes.append { mount ::LoginHelper::Engine, at: "/send-login-mail" }

  class LoginHelper::LoginHelperController < ::ApplicationController
    skip_before_action :preload_json, :check_xhr, :redirect_to_login_if_required

    def send_login_mail
      raise Discourse::NotFound if !SiteSetting.enable_local_logins_via_email
      return redirect_to path("/") if current_user

      expires_now
      params.require(:login)

      RateLimiter.new(nil, "email-login-hour-#{request.remote_ip}", 6, 1.hour).performed!
      RateLimiter.new(nil, "email-login-min-#{request.remote_ip}", 3, 1.minute).performed!
      user = User.human_users.find_by_username_or_email(params[:login])
      user_presence = user.present? && !user.staged

      if user
        RateLimiter.new(nil, "email-login-hour-#{user.id}", 6, 1.hour).performed!
        RateLimiter.new(nil, "email-login-min-#{user.id}", 3, 1.minute).performed!

        if user_presence
          DiscourseEvent.trigger(:before_email_login, user)

          email_token =
            user.email_tokens.create!(email: user.email, scope: EmailToken.scopes[:email_login])

          Jobs.enqueue(
            :critical_user_email,
            type: "email_login",
            user_id: user.id,
            email_token: email_token.token,
          )
        end
      end

      @to = params[:login]

      json = success_json
      json[:hide_taken] = SiteSetting.hide_email_address_taken
      json[:user_found] = user_presence unless SiteSetting.hide_email_address_taken

      append_view_path(File.expand_path("../app/views", __FILE__))
      render template: "send_login_mail", layout: "no_ember", locals: { hide_auth_buttons: true }
    rescue RateLimiter::LimitExceeded
      # TODO: test
      render_error(I18n.t("rate_limiter.slow_down"))
    end
  end

  module LoginHelper
    module BuildEmailHelperExtension
      def build_email(to, opts)
        opts ||= {}
        # puts "🔵 build_email opts=#{opts.to_yaml}"
        opts[:url] += "?" + URI.encode_www_form({ login: to }).to_s if opts.key?(:url)
        super(to, opts)
      end
    end

    module MessageBuilderExtension
      def initialize(to, opts = nil)
        opts ||= {}
        @to = to
        # puts "🔵 MBE::init opts=#{opts.to_yaml}"
        if html_override = opts[:html_override]
          fragment = Nokogiri::HTML5.fragment(html_override)
          fragment
            .css("a")
            .each do |a|
              if a["href"]
                a["href"] = add_user_to_forum_links(a["href"]) if a["href"]
                # puts "🟡 a #{a.to_html}🟡"
              end
            end
          opts[:html_override] = fragment.to_html
        end
        super(to, opts)
      end

      def body
        body = super()
        # puts "🔵 body #{body.to_json}"
        body.gsub!(URI.regexp) { |match| add_user_to_forum_links(match) } if body && body.present?
        body
      end

      def add_user_to_forum_links(link)
        return link unless link.present?
        if links_to_our_discourse?(link) && !link.include?("/session")
          # puts "🔵 Changed #{link}"
          link = URI.parse(link)
          query = URI.decode_www_form(link.query || "")
          link.query = URI.encode_www_form(query << ["login", @to])
          link.to_s
        else
          # puts "🟡 UNCHANGED #{link}"
          link
        end
      end

      def links_to_our_discourse?(link)
        our_domain = URI.parse(Discourse.base_url).host
        linked_domain = URI.parse(link).host
        puts "🔵 links_to_our_discourse? #{our_domain} == #{linked_domain}"
        linked_domain == our_domain
      end
    end

    module SessionControllerExtension
      def send_email_login
      end
    end

    # if username is provided in url, redirect to login page directly on invalid access if user is not logged in
    module ApplicationControllerExtension
      def rescue_discourse_actions(type, status_code, opts = nil)
        # puts "🟣 rescue_discourse_actions type=#{type} opts=#{opts}"

        return super(type, status_code, opts) if type != :invalid_access || current_user.present?

        # puts "🔵 rescue_discourse_actions type=#{type} opts=#{opts}"
        # puts "🔵 PATH_INFO=#{request.env["PATH_INFO"]}"
        # puts "🔵 params #{params}"
        # puts "🔵 current_user #{current_user} present: #{current_user.present?}"

        cookies[:email] = params[:login] if params[:login].present?
        cookies[:email] ||= params[:email] if params[:email].present?
        cookies[:email] ||= params[:username] if params[:username].present?
        cookies[:destination_url] = request.env["PATH_INFO"]

        if cookies[:email].present?
          # TODO:
          # - send email to user with login link
          # - redirect to message page

          redirect_to "/u/send-email-login"
        else
          super(type, status_code, opts)
        end
      end
    end
  end

  reloadable_patch do |plugin|
    ApplicationController.prepend LoginHelper::ApplicationControllerExtension
    SessionController.prepend LoginHelper::SessionControllerExtension

    UserNotifications.class_eval { prepend LoginHelper::BuildEmailHelperExtension }
    Email::MessageBuilder.prepend LoginHelper::MessageBuilderExtension
  end
end
