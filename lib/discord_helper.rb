require 'json'
require 'net/http'
require 'uri'
require 'securerandom'

# event.defer 後のフォローアップとしてファイルを送信する。
# discordrb の send_message はファイル添付不可のため、Discord Webhook API を直接 POST する。
def send_interaction_followup_file(application_id, token, image_bytes, filename)
  boundary     = SecureRandom.hex(16)
  payload_json = JSON.generate({ attachments: [{ id: 0, filename: filename }] })

  body = [
    "--#{boundary}\r\n",
    "Content-Disposition: form-data; name=\"payload_json\"\r\n",
    "Content-Type: application/json\r\n\r\n",
    payload_json,
    "\r\n--#{boundary}\r\n",
    "Content-Disposition: form-data; name=\"files[0]\"; filename=\"#{filename}\"\r\n",
    "Content-Type: application/octet-stream\r\n\r\n",
    image_bytes,
    "\r\n--#{boundary}--\r\n",
  ].join

  uri = URI("https://discord.com/api/v10/webhooks/#{application_id}/#{token}")
  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl      = true
  http.read_timeout = 15
  http.open_timeout = 10

  request = Net::HTTP::Post.new(uri)
  request['Content-Type'] = "multipart/form-data; boundary=#{boundary}"
  request.body = body

  http.request(request)
rescue StandardError => e
  warn "followup file send failed: #{e}"
end
