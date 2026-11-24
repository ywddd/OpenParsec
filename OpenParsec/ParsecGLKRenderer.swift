import GLKit
import ParsecSDK

private let glPreRenderCallback: ParsecPreRenderCallback = { opaque in
	guard let opaque = opaque else { return true }
	let context = Unmanaged<ParsecGLViewportContext>.fromOpaque(opaque).takeUnretainedValue()
	glViewport(GLsizei(context.x), GLsizei(context.y), GLsizei(context.width), GLsizei(context.height))
	glScissor(GLsizei(context.x), GLsizei(context.y), GLsizei(context.width), GLsizei(context.height))
	return true
}

final class ParsecGLViewportContext {
	var x: Int = 0
	var y: Int = 0
	var width: Int = 0
	var height: Int = 0
}

class ParsecGLKRenderer: NSObject, GLKViewDelegate, GLKViewControllerDelegate {
	var glkView: GLKView
	var glkViewController: GLKViewController

	var lastWidth: CGFloat = 1.0
	var lastScale: CGFloat = 0

	var lastImg: CGImage?
	let updateImage: () -> Void
	let viewportContext = ParsecGLViewportContext()
	var displayMode: StreamDisplayMode = .fill

	private var drawnFrames = 0
	private var lastRateSample = CACurrentMediaTime()

	init(_ view: GLKView, _ viewController: GLKViewController, _ updateImage: @escaping () -> Void) {
		self.updateImage = updateImage
		glkView = view
		glkViewController = viewController

		super.init()

		glkView.delegate = self
		glkViewController.delegate = self

	}

	deinit
	{
		glkView.delegate = nil
		glkViewController.delegate = nil
	}

	func glkView(_ view: GLKView, drawIn rect: CGRect) {
		if glkViewController.isPaused { return }

		// timeout in ms: 16ms = ~60fps, 8ms = ~120fps
		let fps = glkViewController.framesPerSecond > 0 ? glkViewController.framesPerSecond : 60
		let timeout = UInt32(max(1000 / fps, 8)) // minimum 8ms for 120Hz

		viewportContext.x = 0
		viewportContext.y = 0
		if displayMode == .fill {
			viewportContext.width = Int(view.drawableWidth)
			viewportContext.height = Int(view.drawableHeight)
		} else {
			let geometry = StreamGeometry(
				viewportSize: CGSize(width: view.drawableWidth, height: view.drawableHeight),
				hostSize: CGSize(width: CGFloat(CParsec.hostWidth), height: CGFloat(CParsec.hostHeight)),
				mode: .fit
			)
			viewportContext.x = Int(((CGFloat(view.drawableWidth) - geometry.contentSize.width) / 2).rounded())
			viewportContext.y = Int(((CGFloat(view.drawableHeight) - geometry.contentSize.height) / 2).rounded())
			viewportContext.width = Int(geometry.contentSize.width.rounded())
			viewportContext.height = Int(geometry.contentSize.height.rounded())
		}
		CParsec.renderGLFrame(timeout: timeout, preRender: glPreRenderCallback, opaque: Unmanaged.passUnretained(viewportContext).toOpaque())

		drawnFrames += 1
		let now = CACurrentMediaTime()
		let elapsed = now - lastRateSample
		if elapsed >= 1 {
			if elapsed <= 2 {
				CParsec.drawRate = Double(drawnFrames) / elapsed
			}
			drawnFrames = 0
			lastRateSample = now
		}

		if #available(iOS 15.0, *) {
			PictureInPictureManager.shared.captureFrame(
				viewWidth: GLsizei(view.drawableWidth),
				viewHeight: GLsizei(view.drawableHeight),
				streamWidth: GLsizei(CParsec.hostWidth),
				streamHeight: GLsizei(CParsec.hostHeight)
			)
		}

		updateImage()

//		glFinish()
		// glFlush()
	}

	func glkViewControllerUpdate(_ controller: GLKViewController) { }
}
