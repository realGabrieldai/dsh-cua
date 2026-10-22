import DshCuaCore
import Foundation

// Thin entry point: all logic lives in DshCuaCore so `swift test` can import it.
let code = await Runner.run(argv: Array(CommandLine.arguments.dropFirst()))
exit(code)
