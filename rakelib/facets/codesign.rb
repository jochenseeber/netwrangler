# frozen_string_literal: true

require_relative "../project"

# Generic macOS code-signing and notarization helpers (no-op off macOS), usable
# by any project. The identity is taken from the CODESIGN_IDENTITY env var (the
# one supported override, so CI can inject a keychain-imported secret),
# otherwise resolved by convention from a 1Password item tagged codesign/<git
# user.email>/<release|debug> (credential field). The Apple account used to
# notarize comes from the item tagged notarize/<git user.email> (username =
# Apple ID, password = app-specific password).
#
# Only the facet block at the bottom contributes anything: requiring this file
# registers the facet and nothing more, so the module functions and
# NotaryCredentials above are callable by whichever facet builds binaries
# (Crystal's, for signing and notarization), whether or not it declared an
# `after:` edge to this one. Called as Codesign.codesign_binary and friends.
module Codesign
  # Extends Rake::DSL so the module functions below — which shell out to
  # codesign, notarytool, plutil, etc. — can call sh/mkdir_p/rm_f directly.
  extend Rake::DSL

  # notarytool refuses a profile name containing `/` ("invalid characters:
  # [Solidus]") and then *prompts* for a replacement, which would silently eat
  # the password piped to its stdin and store it as a profile name. Reject such
  # a name ourselves so that prompt is never reached.
  PROFILE_INVALID = %r{/}

  # The credentials needed to create the notarytool keychain profile: its name,
  # the Apple ID, and the app-specific password.
  NotaryCredentials = Data.define(:profile, :apple_id, :password)

  module_function

  # The notarytool keychain profile holding the credentials for +email+. The
  # name is a local label rather than a secret, so it follows this convention
  # (keeping one profile per Apple account on a machine) and is overridable with
  # NOTARY_PROFILE; the credentials behind it live in the keychain, put there by
  # notary:setup.
  def notary_profile_name(email) = "Notarize #{email}"

  # The 1Password tag of the item holding the Apple ID (`username`) and
  # app-specific password (`password`) used to create the keychain profile.
  def notary_login_tag(email) = "notarize/#{email}"

  # The configured git user email, used to key the 1Password lookup.
  def git_user_email
    email = capture("git", "config", "user.email").to_s.strip
    email.empty? ? nil : email
  end

  # The 1Password account UUID whose email matches +email+ (op --account matches a
  # UUID/shorthand/sign-in address, never an email). Returns nil to fall back to
  # op's default account.
  def op_account_for(email)
    listed = capture("op", "account", "list", "--format=json")
    return nil if listed.nil? || listed.empty?

    match = JSON.parse(listed).find { |account| account["email"] == email }
    match && match["account_uuid"]
  end

  # The op arguments scoping a call to the account whose sign-in email is
  # +email+ (empty to use op's default account).
  def op_account_args(email)
    account = op_account_for(email)
    account ? ["--account", account] : []
  end

  # The value of one field of a 1Password item, or nil. op returns a single
  # object rather than an array when only one field matches.
  def op_item_field(id:, label:, account_args:)
    fetched = capture("op", "item", "get", id, "--fields", "label=#{label}", "--reveal", "--format=json", *account_args)
    return nil if fetched.nil? || fetched.empty?

    fields = JSON.parse(fetched)
    field = fields.is_a?(Array) ? fields.first : fields
    field && field["value"]
  end

  # The id of the first 1Password item tagged +tag+, or nil when none matches.
  def onepassword_item_id(tag:, account_args:)
    listed = capture("op", "item", "list", "--tags", tag, "--format=json", *account_args)
    return nil if listed.nil? || listed.empty?

    items = JSON.parse(listed)
    items.empty? ? nil : items.first["id"]
  end

  # Resolve the `credential` field of the first 1Password item tagged +tag+,
  # scoped to the account matching +email+. Returns nil when the item or field
  # is unavailable.
  def onepassword_credential(email:, tag:)
    account_args = op_account_args(email)
    id = onepassword_item_id(tag: tag, account_args: account_args)
    return nil if id.nil?

    value = op_item_field(id: id, label: "credential", account_args: account_args)
    value.nil? || value.empty? ? nil : value
  end

  # Resolve the codesign identity from the `credential` field of the 1Password
  # item tagged codesign/<git user.email>/<release|debug>. Returns nil when the
  # item, field, or git user email is unavailable.
  def onepassword_codesign_identity(release:)
    email = git_user_email
    return nil if email.nil? || email.empty?

    onepassword_credential(email: email, tag: "codesign/#{email}/#{release ? "release" : "debug"}")
  end

  # Resolve the signing identity: CODESIGN_IDENTITY overrides; only when it is
  # unset does the 1Password lookup run. Release builds abort without one (the
  # Secure Enclave rejects ad-hoc signatures); debug builds fall back to ad-hoc.
  def codesign_identity(release:)
    identity = ENV.fetch("CODESIGN_IDENTITY", nil)
    identity = onepassword_codesign_identity(release: release) if identity.nil? || identity.empty?
    if identity.nil? || identity.empty?
      if release
        abort "release signing needs an Apple Developer identity: set CODESIGN_IDENTITY, " \
              "or add a 1Password item tagged codesign/#{git_user_email || "<git-user-email>"}/release " \
              "with a `credential` field holding the cert SHA-1 (the Secure Enclave rejects ad-hoc signatures)"
      end
      return "-"
    end
    identity
  end

  # Write +entitlements+ (a plist dictionary as key => value) to +path+ and return it.
  #
  # Serialized through JSON and `plutil` rather than assembled as XML here: a plist is
  # structured data, and a value carrying a `<` or a `&` would corrupt a hand-written
  # document while passing every test that only ever used a boolean.
  #
  # Which entitlements a binary needs is the project's business, not this file's — see
  # `crystal.components.<component>.entitlements` for the ones a Crystal binary does.
  def write_entitlements_plist(entitlements:, path:)
    mkdir_p File.dirname(path)
    converted = IO.popen(["plutil", "-convert", "xml1", "-o", path, "--", "-"], "w") do |plutil|
      plutil.write(JSON.generate(entitlements))
    end
    abort "plutil could not write the entitlements plist #{path}" unless $CHILD_STATUS.success?

    converted && path
  end

  # The dynamic libraries a binary loads from outside the OS's own signed set.
  # Library validation — which the hardened runtime turns on — rejects any
  # non-platform library whose Team ID differs from the signing process's, so a
  # hardened binary linking one of these cannot start at all.
  def non_platform_dylibs(path:)
    capture("otool", "-L", path).to_s
      .lines
      .drop(1) # first line is the binary's own path
      .map { |line| line.strip.sub(%r{\s+\(compatibility.*\z}, "") }
      .reject(&:empty?)
      .reject { |lib| lib.start_with?("/usr/lib/", "/System/") }
  end

  # Code-sign a freshly built binary on macOS (no-op elsewhere).
  #
  # +identifier+ pins the signing identifier. Without it codesign derives one from
  # the file name and appends a hash (my-tool-5555…), which no code-signing
  # requirement can usefully pin — so a peer check written against the intended
  # identifier silently matches nothing.
  #
  # +hardened+ enables the hardened runtime, and with it library validation. It
  # defaults to on for every mode, and a binary that links a non-platform dylib
  # aborts rather than being signed unhardened: such a binary dies at launch with
  # a Team ID mismatch rather than failing at sign time, so accepting it silently
  # would ship something that cannot start. Pass false to deliberately sign
  # without hardening, which warns — an unhardened binary can be taken over with
  # DYLD_INSERT_LIBRARIES however carefully it is signed, so a verified signature
  # on one says nothing about the code that ends up running.
  #
  # +entitlements+ is a plist path, applied only when hardening and supplied by the
  # caller — which entitlements a binary needs depends on the language runtime and the
  # project, neither of which this file knows about (write_entitlements_plist builds one
  # from a declared dictionary). The hardened runtime denies capabilities a language
  # runtime may need, and a binary missing one signs and verifies cleanly, then fails at
  # runtime; verify_codesign_entitlements below catches the case where a requested
  # entitlement never reached the signature, but nothing here can know one was needed
  # and never requested.
  #
  # Release builds sign with a secure timestamp (required by notarization, and
  # needs network access to Apple's timestamp server); debug builds skip it so
  # they sign offline.
  def codesign_binary(path:, release:, identifier: nil, hardened: true, entitlements: nil)
    return unless Platform.detect.ostype == "darwin"

    identity = codesign_identity(release: release)
    warn "WARNING: ad-hoc signing; the Secure Enclave will not engage (falls back to in-memory)" if identity == "-"

    blockers = non_platform_dylibs(path: path)
    if hardened && !blockers.empty?
      listed = blockers.map { |lib| "  #{lib}" }.join("\n")
      abort "cannot apply the hardened runtime to #{path}: it links libraries that " \
            "library validation rejects at launch, so the binary would not start:\n#{listed}\n" \
            "static-link them, or pass hardened: false to accept an unhardened binary"
    end
    unless hardened
      warn "WARNING: #{File.basename(path)} is signed without the hardened runtime; " \
           "DYLD_INSERT_LIBRARIES injection is possible, so a verified code signature " \
           "does not imply code integrity"
    end

    applied_entitlements = hardened ? entitlements : nil
    abort "entitlements file not found: #{applied_entitlements}" if applied_entitlements && !File.exist?(applied_entitlements)

    args = ["--sign", identity, "--force"]
    args += ["--identifier", identifier] if identifier
    args += ["--options", "runtime"] if hardened
    args += ["--entitlements", applied_entitlements] if applied_entitlements
    args += release ? ["--timestamp"] : ["--timestamp=none"]
    sh("codesign", *args, path)

    verify_codesign_binary(path: path, identifier: identifier, hardened: hardened,
                           release: release, entitlements: applied_entitlements)
  end

  # Verify one signed binary on macOS (no-op elsewhere), asserting it carries the
  # properties that were asked for rather than merely a valid signature.
  # `--verify --strict` passes happily on a binary whose identifier was derived
  # instead of pinned, which is exactly how that defect went unnoticed.
  def verify_codesign_binary(path:, identifier: nil, hardened: false, release: false,
                             entitlements: nil)
    return unless Platform.detect.ostype == "darwin"

    sh("codesign", "--verify", "--strict", "--verbose=2", path)

    described = capture_merged("codesign", "--display", "--verbose=2", path).to_s
    actual_identifier = described[%r{^Identifier=(.*)$}, 1]
    flags = described[%r{flags=[^(]*\(([^)]*)\)}, 1].to_s.split(",")

    if identifier && actual_identifier != identifier
      abort "codesign identifier mismatch for #{path}: asked for #{identifier.inspect}, " \
            "got #{actual_identifier.inspect}"
    end
    if hardened && !flags.include?("runtime")
      abort "codesign did not apply the hardened runtime to #{path} (flags: #{flags.join(",")})"
    end
    if release && described.match?(%r{^TeamIdentifier=not set$})
      abort "release signature for #{path} carries no Team Identifier; it was signed ad-hoc"
    end
    verify_codesign_entitlements(path: path, entitlements: entitlements) if entitlements

    sh("codesign", "--display", "--requirements", "-", path)
  end

  # Confirm every key the entitlements plist requests actually reached the
  # signature. A missing entitlement is the worst failure mode available here: the
  # binary signs, verifies, and satisfies its designated requirement, then dies the
  # first time it uses the capability.
  def verify_codesign_entitlements(path:, entitlements:)
    applied = capture_merged("codesign", "--display", "--entitlements", "-", path).to_s
    requested = File.read(entitlements).scan(%r{<key>([^<]+)</key>}).flatten
    missing = requested.reject { |key| applied.include?(key) }
    return if missing.empty?

    abort "codesign did not apply #{missing.join(", ")} to #{path}; the binary will " \
          "fail at runtime the first time it needs that capability"
  end

  # The notarytool keychain profile name: NOTARY_PROFILE, else
  # notary-<git user.email>. The profile itself is created once per machine by
  # `rake notary:setup`, which keeps the Apple ID credentials in the keychain so
  # no secret ever appears on a command line.
  def notary_profile
    override = ENV.fetch("NOTARY_PROFILE", nil)
    profile = if override.nil? || override.empty?
      email = git_user_email
      abort "git user.email is not set; cannot name the notarytool keychain profile" if email.nil?
      notary_profile_name(email)
    else
      override
    end

    abort "notarytool rejects `/` in a keychain profile name: #{profile}" if profile.match?(PROFILE_INVALID)

    profile
  end

  # Notarize a signed release binary on macOS (no-op elsewhere): zip it (a bare
  # Mach-O cannot be submitted directly), upload with notarytool, and wait for
  # Apple's verdict. Nothing is stapled — a ticket cannot be stapled to a bare
  # binary; Gatekeeper on the target machine fetches it from Apple instead.
  # Ad-hoc-signed binaries (CODESIGN_IDENTITY=-) are skipped: Apple only
  # notarizes Developer ID signatures.
  def notarize_binary(path:)
    return unless Platform.detect.ostype == "darwin"

    if codesign_identity(release: true) == "-"
      warn "WARNING: ad-hoc signature; skipping notarization"
      return
    end

    profile = notary_profile
    zip = File.join(".work", "#{File.basename(path)}-notarize.zip")
    mkdir_p ".work"
    sh("ditto", "-c", "-k", path, zip)
    submitted = capture("xcrun", "notarytool", "submit", zip,
                        "--keychain-profile", profile, "--wait", "--output-format", "json")
    rm_f zip
    if submitted.nil?
      abort "notarytool submit failed for #{path}: no keychain profile `#{profile}` " \
            "(create it with `rake notary:setup`), or no network access to Apple"
    end

    verdict = JSON.parse(submitted)
    puts "notarization of #{File.basename(path)}: #{verdict["status"]} (submission #{verdict["id"]})"
    return if verdict["status"] == "Accepted"

    abort "notarization was not accepted; inspect with: " \
          "xcrun notarytool log #{verdict["id"]} --keychain-profile #{profile}"
  end

  # The credentials for creating the keychain profile: the profile name, plus
  # the Apple ID (`username`) and app-specific password (`password`) from the
  # item tagged notarize/<git user.email>. Aborts when the item or a field is
  # missing — setup cannot proceed without them.
  def onepassword_notary_credentials
    email = git_user_email
    abort "git user.email is not set; cannot locate the notarize 1Password item" if email.nil?

    tag = notary_login_tag(email)
    account_args = op_account_args(email)
    id = onepassword_item_id(tag: tag, account_args: account_args)
    abort "no item tagged #{tag} in the 1Password account for #{email}" if id.nil?

    fields = %w[username password].to_h do |label|
      [label, op_item_field(id: id, label: label, account_args: account_args)]
    end
    missing = fields.select { |_, value| value.nil? || value.empty? }.keys
    abort "the 1Password item tagged #{tag} is missing the fields: #{missing.join(", ")}" unless missing.empty?

    NotaryCredentials.new(profile: notary_profile, apple_id: fields["username"], password: fields["password"])
  end

  # The team ID of the signing certificate in the keychain matching +identity+ —
  # the parenthesized suffix of the certificate name, e.g. (H26CFY9N42). Works
  # whether +identity+ is the cert SHA-1 or the certificate name.
  def keychain_team_id(identity)
    listed = capture("security", "find-identity", "-v", "-p", "codesigning")
    abort "security find-identity failed; is the keychain accessible?" if listed.nil?

    line = listed.lines.find { |candidate| candidate.include?(identity) }
    team = line && line[%r{\(([0-9A-Z]+)\)"}, 1]
    abort "no keychain signing certificate matches the identity #{identity}" if team.nil?

    team
  end

  # Store the notarytool keychain profile named in 1Password so release builds
  # can notarize, taking the team ID from the release signing certificate. The
  # app-specific password is piped to notarytool's stdin prompt — deliberately
  # neither argv nor environment, so other processes can never see it. notarytool
  # validates the credentials with Apple before saving them to the keychain.
  def store_notary_credentials
    abort "the notary profile lives in the macOS keychain; run this on macOS" unless Platform.detect.ostype == "darwin"

    credentials = onepassword_notary_credentials
    team = keychain_team_id(codesign_identity(release: true))
    command = ["xcrun", "notarytool", "store-credentials", credentials.profile,
               "--apple-id", credentials.apple_id, "--team-id", team,]
    output = IO.popen(command, "r+") do |io|
      io.puts(credentials.password)
      io.close_write
      io.read
    end
    abort "notarytool store-credentials failed:\n#{output}" unless $CHILD_STATUS.success?

    puts "stored notarytool keychain profile #{credentials.profile} (validated by Apple)"
  end
end

# Codesign names no `after:`: it reads nothing from the model beyond `capture`, and
# defines the one task every platform lists (though it only works on macOS, where the
# keychain it stores into lives).
facet :codesign do
  namespace "notary" do
    desc "Store the notarytool keychain profile (credentials from 1Password)"
    task "setup" do
      Codesign.store_notary_credentials
    end
  end
end
