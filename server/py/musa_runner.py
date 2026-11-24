"""Runs one visualiser script inside the sandbox and keeps what it shows.

The script runs with its output folder as the working directory, so any file
it writes (savefig, write_html, image.save, mesh.export) appears in the
Visualiser. Calls that would normally open a window are turned into files:

  matplotlib  plt.show()          -> figure-N.png (animations -> animation-N.gif)
  PIL         Image.show()        -> image-N.png
  plotly      fig.show()          -> plot-N.html

Nothing here talks to the network; the sandbox has none.
"""
import os
import runpy
import sys
import traceback

OUT = os.environ.get("MUSA_OUT") or os.getcwd()
SCRIPT = sys.argv[1]
_counter = {"figure": 0, "image": 0, "plot": 0, "animation": 0}


def _next(kind, ext):
    _counter[kind] += 1
    return os.path.join(OUT, f"{kind}-{_counter[kind]}.{ext}")


def _patch_matplotlib():
    try:
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
        from matplotlib import animation
    except Exception:
        return
    live_animations = []
    original_init = animation.Animation.__init__

    def tracking_init(self, *a, **k):
        original_init(self, *a, **k)
        live_animations.append(self)

    animation.Animation.__init__ = tracking_init

    def show(*_a, **_k):
        saved_figs = set()
        while live_animations:
            anim = live_animations.pop(0)
            fig = getattr(anim, "_fig", None)
            try:
                anim.save(_next("animation", "gif"), writer=animation.PillowWriter(fps=20))
                if fig is not None:
                    saved_figs.add(fig.number)
            except Exception as e:  # keep going: the still frame is better than nothing
                print(f"[musa] could not save animation: {e}", file=sys.stderr)
        for num in plt.get_fignums():
            if num in saved_figs:
                continue
            plt.figure(num).savefig(_next("figure", "png"), dpi=144, bbox_inches="tight")
        plt.close("all")

    plt.show = show
    return show


def _patch_pil():
    try:
        from PIL import Image
    except Exception:
        return

    def show(self, *_a, **_k):
        self.save(_next("image", "png"))

    Image.Image.show = show


def _patch_plotly():
    try:
        import plotly.basedatatypes as bdt
    except Exception:
        return

    def show(self, *_a, **_k):
        self.write_html(_next("plot", "html"), include_plotlyjs=True)

    bdt.BaseFigure.show = show


def main():
    os.makedirs(OUT, exist_ok=True)
    os.chdir(OUT)
    project = os.environ.get("MUSA_PROJECT_DIR")
    if project and project not in sys.path:
        sys.path.insert(0, project)
    show = _patch_matplotlib()
    _patch_pil()
    _patch_plotly()
    code = 0
    try:
        runpy.run_path(SCRIPT, run_name="__main__")
    except SystemExit as e:
        code = e.code if isinstance(e.code, int) else (0 if e.code is None else 1)
    except BaseException:
        traceback.print_exc()
        code = 1
    # Figures left open at the end are kept too, as a notebook would show them.
    if show is not None:
        try:
            show()
        except Exception:
            traceback.print_exc()
    sys.exit(code)


if __name__ == "__main__":
    main()
