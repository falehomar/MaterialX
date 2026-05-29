package materialx;

import javax.swing.*;
import java.awt.*;
import java.lang.foreign.*;
import java.lang.invoke.MethodHandle;
import java.nio.file.Path;
import java.nio.file.Paths;

public class MaterialXViewer {
    public static void main(String[] args) throws Throwable {
        // Open a Swing JFrame before calling any MaterialX logic
        SwingUtilities.invokeAndWait(() -> {
            JFrame frame = new JFrame("MaterialX Java Host Panel");
            frame.setDefaultCloseOperation(JFrame.DISPOSE_ON_CLOSE);
            frame.setSize(500, 200);
            frame.setLayout(new BorderLayout());
            
            JLabel titleLabel = new JLabel("MaterialX Java Controller", SwingConstants.CENTER);
            titleLabel.setFont(new Font("Arial", Font.BOLD, 18));
            titleLabel.setBorder(BorderFactory.createEmptyBorder(20, 20, 20, 20));
            frame.add(titleLabel, BorderLayout.CENTER);
            
            JLabel statusLabel = new JLabel("Launching native macOS Metal Viewer...", SwingConstants.CENTER);
            statusLabel.setForeground(Color.GRAY);
            statusLabel.setBorder(BorderFactory.createEmptyBorder(0, 0, 20, 0));
            frame.add(statusLabel, BorderLayout.SOUTH);
            
            frame.setLocationRelativeTo(null);
            frame.setVisible(true);
        });

        String libName = System.mapLibraryName("MaterialXViewJava");
        String libPathStr = System.getProperty("materialx.lib.path");
        Path libPath;
        if (libPathStr != null) {
            libPath = Paths.get(libPathStr).resolve(libName).toAbsolutePath();
        } else {
            libPath = Paths.get(libName).toAbsolutePath();
        }

        System.out.println("Loading native library: " + libPath);
        SymbolLookup lookup = SymbolLookup.libraryLookup(libPath, Arena.global());
        MemorySegment runViewerAddress = lookup.find("runViewer")
                .orElseThrow(() -> new RuntimeException("Symbol 'runViewer' not found"));

        FunctionDescriptor descriptor = FunctionDescriptor.of(
                ValueLayout.JAVA_INT,      // return value (int)
                ValueLayout.JAVA_INT,      // argc (int)
                ValueLayout.ADDRESS         // argv (char**)
        );

        MethodHandle runViewer = Linker.nativeLinker().downcallHandle(runViewerAddress, descriptor);

        try (Arena arena = Arena.ofConfined()) {
            int argc = args.length + 1;
            MemorySegment argv = arena.allocate(ValueLayout.ADDRESS, argc);

            MemorySegment arg0 = arena.allocateFrom("MaterialXView");
            argv.setAtIndex(ValueLayout.ADDRESS, 0, arg0);

            for (int i = 0; i < args.length; i++) {
                MemorySegment arg = arena.allocateFrom(args[i]);
                argv.setAtIndex(ValueLayout.ADDRESS, i + 1, arg);
            }

            System.out.println("Launching MaterialXView from Java FFM API...");
            int result = (int) runViewer.invokeExact(argc, argv);
            System.out.println("MaterialXView exited with code: " + result);
            System.exit(result);
        }
    }
}
