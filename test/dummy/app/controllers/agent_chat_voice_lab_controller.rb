# The shared agent chat with hold to talk on it, rendered the way an app renders
# it: `render "studio/agent_chat/chat", ..., voice: true`. Its session is real, so
# the mic's gates read a real current_user: signed out, /agent_chat_voice_lab has
# no mic. Outside /lab because e2e_lab_isolation_test visits every /lab route in a
# process with no users table. e2e/agent_chat_voice.spec.js drives it in a browser
# and test/integration/agent_chat_proxy_test.rb renders it.
class AgentChatVoiceLabController < ActionController::Base
  include Studio::ErrorHandling

  skip_before_action :require_authentication
  helper E2eLabController::AssetDelivery
  layout "e2e_lab"

  def show; end

  # The browser lane's sign-in door: a verified user, created on first use. The
  # hub keeps one thread per email, so ?as= gives a spec its own empty thread.
  def sign_in
    user = User.find_or_create_by!(email: "talker-#{params[:as].to_s.gsub(/\W/, "")}@lab.test") do |row|
      row.email_verified_at = Time.current
      row.username = "lab-talker"
      row.role = "user"
    end
    session[Studio.session_key] = user.id
    redirect_to agent_chat_voice_lab_path
  end
end
