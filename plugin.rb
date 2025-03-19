# name: discourse-login-helper
# about: shorten process of logging in by email
# version: 0.10
# authors: Thomas Kalka
# url: https://github.com/thoka/discourse-login-helper
# meta_topic_id: 309676
# frozen_string_literal: true

enabled_site_setting :login_helper_enabled
PLUGIN_NAME ||= "login-helper".freeze

after_initialize do
  # if username is provided in url, we redirect to login page directly providing the username in cookies

  module ::LoginHelper
    class Engine < ::Rails::Engine
      engine_name PLUGIN_NAME
      isolate_namespace LoginHelper
    end
  end

  ::LoginHelper::Engine.routes.draw do
    get "/send-login-mail" => "login_helper#send_login_mail"
    post "/redirect-to-login" => "login_helper#redirect_to_login"
  end
  ::Discourse::Application.routes.append { mount ::LoginHelper::Engine, at: "/login-helper" }

  class LoginHelper::LoginHelperController < ::ApplicationController
    skip_before_action :preload_json, :check_xhr, :redirect_to_login_if_required

    def send_login_mail
      raise Discourse::NotFound if !SiteSetting.enable_local_logins_via_email
      raise Discourse::NotFound if !SiteSetting.login_helper_enabled

      return redirect_to path("/") if current_user

      expires_now
      @to = params.require(:login)
      @destination_url = params.require(:destination_url)

      RateLimiter.new(nil, "email-login-hour-#{request.remote_ip}", 6, 1.hour).performed!
      RateLimiter.new(nil, "email-login-min-#{request.remote_ip}", 3, 1.minute).performed!
      user = User.human_users.find_by_username_or_email(@to)
      user_presence = user.present? && !user.staged

      if user
        RateLimiter.new(nil, "email-login-hour-#{user.id}", 6, 1.hour).performed!
        RateLimiter.new(nil, "email-login-min-#{user.id}", 3, 1.minute).performed!

        if user_presence
          DiscourseEvent.trigger(:before_email_login, user)

          email_token =
            user.email_tokens.create!(
              email: user.email,
              scope: EmailToken.scopes[:email_login],
              destination_url: @destination_url,
            )

          Jobs.enqueue(
            :critical_user_email,
            type: "email_login",
            user_id: user.id,
            email_token: email_token.token,
          )
        end
      end

      @to = params[:login]

      append_view_path(File.expand_path("../app/views", __FILE__))
      render template: "send_login_mail", layout: "no_ember", locals: { hide_auth_buttons: true }
    rescue RateLimiter::LimitExceeded
      # TODO: test
      render_error(I18n.t("rate_limiter.slow_down"))
    end

    def redirect_to_login
      destination_url = params.require(:destination_url)
      login = params.require(:login)
      cookies[:email] = { value: login, expires: 1.hour.from_now }
      cookies[:destination_url] = { value: destination_url, expires: 1.hour.from_now }
      redirect_to "/login"
    end
  end

  module ::LoginHelper
    @@our_domain = URI.parse(Discourse.base_url).host

    class << self
      def add_user_to_forum_links(link, username)
        # puts "🔵 add_user_to_forum_links link=#{link} username=#{username}"
        return link if link.blank?
        escaped_link = escape_non_ascii(link)
        parsed_link = URI.parse(escaped_link)

        if links_to_our_discourse?(parsed_link)
          is_category = parsed_link.path&.start_with?("/c/")
          is_topic = parsed_link.path&.start_with?("/t/")

          if is_category || is_topic
            query = URI.decode_www_form(parsed_link.query || "")
            parsed_link.query = URI.encode_www_form(query << ["login", username])
            return parsed_link.to_s
          end
        end
        link
      rescue StandardError
        link
      end

      def links_to_our_discourse?(parsed_link)
        # puts "🟡?? to=#{parsed_link.host} here=#{@@our_domain}"
        parsed_link.host == @@our_domain || parsed_link.host == "127.0.0.1"
      end

      def escape_non_ascii(s)
        s.chars.map { |char| char.ascii_only? ? char : CGI.escape(char) }.join
      end
    end

    # module BuildEmailHelperExtension
    #   def build_email(to, opts)
    #     opts ||= {}
    #     # puts "🔵 build_email opts=#{opts.to_yaml}"
    #     opts[:url] += "?" + URI.encode_www_form({ login: to }).to_s if opts.key?(:url)
    #     super(to, opts)
    #   end
    # end

    module MessageBuilderExtension
      def initialize(to, opts = nil)
        opts ||= {}
        @to = to
        # puts "🔵 MBE::init opts=#{opts.to_yaml}"
        if SiteSetting.login_helper_enabled && html_override = opts[:html_override]
          fragment = Nokogiri::HTML5.fragment(html_override)
          fragment
            .css("a")
            .each do |a|
              if a["href"]
                a["href"] = LoginHelper.add_user_to_forum_links(a["href"], @to) if a["href"]
                # puts "🟡 a #{a.to_html}🟡"
              end
            end
          opts[:html_override] = fragment.to_html
        end
        super(to, opts)
      end

      def body
        body = super()
        return body unless SiteSetting.login_helper_enabled
        # puts "🔵 body #{body.to_json}"
        if body && body.present?
          body.gsub!(URI.regexp) { |match| LoginHelper.add_user_to_forum_links(match, @to) }
        end
        body
      end
    end

    module SessionControllerExtension
      def email_login
        # puts "🔵 email_login params: #{params.to_json}"
        token = params[:token]
        matched_token = EmailToken.confirmable(token, scope: EmailToken.scopes[:email_login])
        user = matched_token&.user

        check_local_login_allowed(user: user, check_login_via_email: true)

        rate_limit_second_factor!(user)

        if user.present? && !authenticate_second_factor(user).ok
          return render(json: @second_factor_failure_payload)
        end

        if user = EmailToken.confirm(token, scope: EmailToken.scopes[:email_login])
          if login_not_approved_for?(user)
            return render json: login_not_approved
          elsif payload = login_error_check(user)
            return render json: payload
          else
            raise Discourse::ReadOnly if staff_writes_only_mode? && !user&.staff?
            user.update_timezone_if_missing(params[:timezone])
            log_on_user(user)

            return(render json: success_json.merge(destination_url: matched_token.destination_url))
          end
        end

        render json: { error: I18n.t("email_login.invalid_token", base_url: Discourse.base_url) }
      end
    end

    # if username is provided in url, redirect to login page directly on invalid access if user is not logged in
    module ApplicationControllerExtension
      def redirect_to_login_if_required
        return super unless SiteSetting.login_helper_enabled
        if !current_user && params[:login].present?
          redirect_to_send_login_mail
        else
          super
        end
      end

      def redirect_to_send_login_mail
        destination_url = request.env["PATH_INFO"]
        l = URI.encode_uri_component params[:login]
        d = URI.encode_uri_component destination_url

        # puts "🟣 ... login=#{l} destination_url=#{d}"

        redirect_to "/login-helper/send-login-mail?login=#{l}&destination_url=#{d}"
      end

      def rescue_discourse_actions(type, status_code, opts = nil)
        # puts "🟣 rescue_discourse_actions type=#{type} opts=#{opts}"

        return super(type, status_code, opts) if type != :invalid_access || current_user.present?

        # puts "🔵 PATH_INFO=#{request.env["PATH_INFO"]}"
        # puts "🔵 params #{params}"
        # puts "🔵 current_user #{current_user} present: #{current_user.present?}"

        if params[:login].present?
          redirect_to_send_login_mail
        else
          super(type, status_code, opts)
        end
      end
    end
  end

  reloadable_patch do |plugin|
    ApplicationController.prepend LoginHelper::ApplicationControllerExtension
    Email::MessageBuilder.prepend LoginHelper::MessageBuilderExtension
    SessionController.prepend LoginHelper::SessionControllerExtension
    # UserNotifications.prepend LoginHelper::BuildEmailHelperExtension
    plugin.register_modifier(:email_renderer_html) do |style, message|
      style
        .fragment
        .css("a")
        .each { |a| a["href"] = LoginHelper.add_user_to_forum_links(a["href"], message.to) }
    end
  end
end
