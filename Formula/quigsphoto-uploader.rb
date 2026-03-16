class QuigsphotoUploader < Formula
  desc "Process and publish photos to Ghost CMS"
  homepage "https://github.com/quigleyb/quigsphoto-uploader"
  license "MIT"

  # Tagged releases will use url/sha256 here once published:
  # url "https://github.com/quigleyb/quigsphoto-uploader/archive/refs/tags/v1.0.0.tar.gz"
  # sha256 "..."

  head "https://github.com/quigleyb/quigsphoto-uploader.git", branch: "main"

  depends_on xcode: ["15.0", :build]
  depends_on :macos

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
