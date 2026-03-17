class QuigsphotoUploader < Formula
  desc "Process and publish photos to Ghost CMS"
  homepage "https://github.com/josephquigley/quigsphoto-uploader"
  license "MIT"

  # Uncomment and update for tagged releases:
  # url "https://github.com/josephquigley/quigsphoto-uploader/archive/refs/tags/v1.0.0.tar.gz"
  # sha256 "..."
  #
  # bottle do
  #   root_url "https://github.com/josephquigley/quigsphoto-uploader/releases/download/v1.0.0"
  #   sha256 cellar: :any_skip_relocation, arm64_sequoia: "..."
  # end

  # Local development — switch to GitHub URL when published:
  # head "https://github.com/josephquigley/quigsphoto-uploader.git", branch: "main"
  head "file:///Users/wash/Developer/tools/quigsphoto-uploader", using: :git, branch: "main"

  depends_on xcode: ["26.0", :build]
  depends_on :macos
  depends_on "gnupg"

  def install
    system "swift", "build",
           "-c", "release",
           "--disable-sandbox",
           "--scratch-path", buildpath/".build"
    bin.install buildpath/".build/release/quigsphoto-uploader"
  end

  test do
    assert_match "Process and publish photos", shell_output("#{bin}/quigsphoto-uploader --help")
  end
end
