%% doomguide.cls -- the doomacracy field guide
%% Same face as the EGCP 1010 lab reports (dldlab.cls): Times body, Caladea
%% headings, bold flush-left heads, table captions above and figure captions
%% below, floats pinned where they are written.  Sections are numbered here,
%% since a reference is read out of order and cross-referenced.

\NeedsTeXFormat{LaTeX2e}
\ProvidesClass{doomguide}[2026/11/13 doomacracy field guide]

\DeclareOption*{\PassOptionsToClass{\CurrentOption}{article}}
\ProcessOptions\relax
\LoadClass[11pt]{article}

\RequirePackage[margin=1in]{geometry}
\RequirePackage{amsmath}
\RequirePackage{newtxtext,newtxmath}
\RequirePackage{caladea}
\newcommand{\dg@headfont}{\fontfamily{Caladea-TLF}\selectfont}
\RequirePackage{microtype}
\RequirePackage[T1]{fontenc}
\RequirePackage{graphicx}
\RequirePackage{booktabs,array,multirow,makecell,tabularx}
\RequirePackage{xcolor}
\RequirePackage{enumitem}
\RequirePackage{titlesec}
\RequirePackage[tableposition=top]{caption}
\RequirePackage{subcaption}
\RequirePackage{noindentafter}
\NoIndentAfterEnv{equation*}
\NoIndentAfterEnv{align*}
\RequirePackage{float}
\restylefloat*{figure}
\restylefloat*{table}
\floatplacement{figure}{H}
\floatplacement{table}{H}
\RequirePackage[american]{circuitikz}
\usetikzlibrary{calc,positioning,arrows.meta,shapes.geometric,fit,decorations.pathreplacing}
\RequirePackage{xstring}
\RequirePackage{needspace}
\RequirePackage{etoolbox}
\RequirePackage{pdflscape}
\RequirePackage[hidelinks]{hyperref}

\ctikzset{logic ports=ieee, logic ports origin=center}
\graphicspath{{./media/}{../}}
\setlist{nosep, leftmargin=1.5em}

% ---- headings: bold, flush left, numbered
\titleformat{\section}{\large\bfseries}{\thesection}{0.8em}{}
\titleformat{\subsection}{\normalsize\bfseries\itshape}{\thesubsection}{0.8em}{}
\titleformat{\subsubsection}[runin]{\normalsize\bfseries}{}{0pt}{}[.]
\titlespacing*{\section}{0pt}{1.4\baselineskip}{0.5\baselineskip}
\titlespacing*{\subsection}{0pt}{0.9\baselineskip}{0.3\baselineskip}
\titlespacing*{\subsubsection}{0pt}{0.6\baselineskip}{0.6em}
\setcounter{secnumdepth}{2}
\pretocmd{\section}{\Needspace{8\baselineskip}}{}{}

% ---- captions: "Table 1. Foo" / "Figure 1. Bar", centred, not bold
\captionsetup{labelsep=period, justification=centering, font=normalsize,
              skip=6pt, singlelinecheck=true}

% ---- title page
\newcommand{\dg@subtitle}{}\newcommand{\subtitle}[1]{\renewcommand{\dg@subtitle}{#1}}
\renewcommand{\maketitle}{%
  \begin{titlepage}
  \dg@headfont\centering
  \vspace*{0.18\textheight}
  {\fontsize{30}{36}\selectfont\@title\par}
  \vspace{18pt}
  {\fontsize{16}{20}\selectfont\dg@subtitle\par}
  \vspace{48pt}
  \begin{tikzpicture}[thick]
    % the six pipeline stages as a little masthead
    \foreach \s [count=\i] in {IF,IF2,ID,EX,MEM,WB}
      \node[draw, minimum width=1.25cm, minimum height=0.7cm, font=\small]
        (m\i) at ({1.9*\i},0) {\s};
    \foreach \i [evaluate=\i as \j using int(\i+1)] in {1,...,5}
      \draw[-{Latex[length=2mm]}] (m\i) -- (m\j);
  \end{tikzpicture}
  \par\vfill
  {\fontsize{14}{18}\selectfont\@author\par}
  \vspace{6pt}
  {\fontsize{12}{16}\selectfont\@date\par}
  \vspace*{0.08\textheight}
  \end{titlepage}%
}

% ---- tables: caption on top, booktabs body
%  \begin{guidetable}{caption}{label}{colspec} ... \end{guidetable}
\newenvironment{guidetable}[3]{%
  \begin{table}[H]\centering\caption{#1}\label{tab:#2}%
  \small\begin{tabular}{#3}\toprule
}{%
  \bottomrule\end{tabular}\end{table}%
}

% ---- common TikZ styles for the block and datapath drawings
\tikzset{
  blk/.style={draw, thick, align=center, font=\small, minimum height=0.9cm, fill=white},
  ram/.style={blk, fill=black!7},
  reg/.style={draw, thick, fill=black!12, minimum width=0.28cm, minimum height=1.1cm},
  sig/.style={-{Latex[length=2.2mm]}, thick},
  bus/.style={-{Latex[length=2.2mm]}, line width=1.6pt},
  bidir/.style={{Latex[length=2.2mm]}-{Latex[length=2.2mm]}, thick},
  lbl/.style={font=\scriptsize, inner sep=1.5pt},
  % a multiplexer: wide on the input (west) side, narrow on the output side
  mux/.style={rectangle, inner sep=0pt, minimum height=1.1cm, minimum width=0.45cm,
    path picture={\draw[line width=1.6pt, fill=white]
      ([shift={(0.4pt,0.4pt)}]path picture bounding box.south west)
      -- ([shift={(0.4pt,-0.4pt)}]path picture bounding box.north west)
      -- ($(path picture bounding box.north east)!0.2!(path picture bounding box.south east)+(-0.4pt,0)$)
      -- ($(path picture bounding box.south east)!0.2!(path picture bounding box.north east)+(-0.4pt,0)$)
      -- cycle;}},
  st/.style={draw, thick, circle, minimum size=1.35cm, align=center, font=\scriptsize, fill=white},
  tr/.style={-{Latex[length=2.2mm]}, thick},
  cond/.style={font=\scriptsize, fill=white, inner sep=1pt, align=center},
  decision/.style={draw, thick, diamond, aspect=2.2, align=center, font=\scriptsize, inner sep=1pt, fill=white},
  % ---- datasheet-style block diagram: hollow bus arrows, width slashes, pins
  pbus/.style={double, double distance=1.8pt, line width=0.5pt, -{Implies[]}},
  pbi/.style={double, double distance=1.8pt, line width=0.5pt, {Implies[]}-{Implies[]}},
  pwire/.style={line width=0.5pt, -{Latex[length=1.6mm]}},
  pblk/.style={draw, line width=0.6pt, align=center, fill=white, inner sep=2pt},
  pin/.style={draw, line width=0.5pt, minimum size=0.2cm, inner sep=0pt, fill=white,
    path picture={\draw[line width=0.4pt]
      (path picture bounding box.south west) -- (path picture bounding box.north east)
      (path picture bounding box.north west) -- (path picture bounding box.south east);}},
  box/.style={draw, thick, rounded corners=3pt, align=center, font=\scriptsize, minimum height=0.75cm, fill=white},
}

% ---- bitfield: a register or instruction word, MSB on the left.
%  \begin{bitfield}{32}            % width in bits
%    \bits{31}{25}{funct7}         % msb, lsb, label (shade with \bits*)
%  \end{bitfield}
% Bit numbers sit above each field's edges, the way the RISC-V manual draws.
\newlength{\dg@bitw}
\newenvironment{bitfield}[2][]{%
  \def\dg@nbits{#2}%
  \setlength{\dg@bitw}{\dimexpr\linewidth/\numexpr#2+2\relax\relax}%
  \ifdim\dg@bitw>1.1cm\setlength{\dg@bitw}{1.1cm}\fi
  \begin{tikzpicture}[x=\dg@bitw, y=0.75cm, font=\small, #1]
}{%
  \end{tikzpicture}%
}
\newcommand{\dg@bits}[4]{%
  \pgfmathsetmacro{\dg@l}{\dg@nbits-1-#1}%
  \pgfmathsetmacro{\dg@r}{\dg@nbits-#2}%
  \draw[thick, fill=#4] (\dg@l,0) rectangle (\dg@r,1);
  \node[font=\tiny] at (\dg@l+0.5,1.22) {#1};
  \ifnum#1=#2\else\node[font=\tiny] at (\dg@r-0.5,1.22) {#2};\fi
}
\newcommand{\bits}{\@ifstar\dg@bitsstar\dg@bitsplain}
\newcommand{\dg@bitsplain}[3]{\dg@bits{#1}{#2}{}{white}%
  \node at ({(\dg@nbits-1-#1+\dg@nbits-#2)/2},0.5) {#3};}
\newcommand{\dg@bitsstar}[3]{\dg@bits{#1}{#2}{}{black!10}%
  \node at ({(\dg@nbits-1-#1+\dg@nbits-#2)/2},0.5) {#3};}
% a caption line under the word, e.g. the format's name on the left
\newcommand{\bitname}[1]{\node[left, font=\small\itshape] at (-0.3,0.5) {#1};}

% ---- kmap: a Karnaugh map, drawn the way the DLD course draws them.
% (Taken from dldlab.cls unchanged.)
\newcounter{dg@loop}
\newcommand{\dg@legend}{}
\newenvironment{kmap}[2]{%
  \def\kmc{#1}\def\kmr{#2}%
  \setcounter{dg@loop}{0}\gdef\dg@legend{}%
  \begin{tikzpicture}[scale=1.0, font=\small, varline/.style={thick},
                      baseline={(current bounding box.north)}]
}{%
  \ifx\dg@legend\@empty\else
  \foreach \kstyle/\klabel [count=\n] in \dg@legend {%
    \draw[thick, \kstyle] (-0.4,{-0.45-0.5*\n}) -- (0.3,{-0.45-0.5*\n});
    \node[right] at (0.4,{-0.45-0.5*\n}) {\klabel};}\fi
  \end{tikzpicture}%
}
\newcommand{\kmapcells}[1]{%
  \foreach \krow [count=\j] in {#1} {%
    \foreach \kv [count=\i] in \krow {%
      \if\kv1\fill[black!10] ({\i-1},{\kmr-\j}) rectangle ++(1,1);\fi
      \node at ({\i-0.5},{\kmr-\j+0.5}) {\kv};}}%
  \draw[step=1cm] (0,0) grid (\kmc,\kmr);%
}
\newcommand{\kmaptop}[3]{%
  \ifnum#1>1 \draw[varline] ({#1-1},\kmr) -- ++(0,0.55);\fi
  \ifnum#2<\kmc \draw[varline] (#2,\kmr) -- ++(0,0.55);\fi
  \node[above] at ({(#1-1+#2)/2},{\kmr+0.05}) {#3};%
}
\newcommand{\kmapbottom}[3]{%
  \ifnum#1>1 \draw[varline] ({#1-1},0) -- ++(0,-0.55);\fi
  \ifnum#2<\kmc \draw[varline] (#2,0) -- ++(0,-0.55);\fi
  \node[below] at ({(#1-1+#2)/2},-0.05) {#3};%
}
\newcommand{\kmapleft}[3]{%
  \ifnum#1>1 \draw[varline] (0,{\kmr-#1+1}) -- ++(-1.35,0);\fi
  \ifnum#2<\kmr \draw[varline] (0,{\kmr-#2}) -- ++(-1.35,0);\fi
  \dg@vlabel{#1}{#2}\node at (-0.7,\dg@vy) {#3};%
}
\newcommand{\kmapright}[3]{%
  \ifnum#1>1 \draw[varline] (\kmc,{\kmr-#1+1}) -- ++(1.35,0);\fi
  \ifnum#2<\kmr \draw[varline] (\kmc,{\kmr-#2}) -- ++(1.35,0);\fi
  \dg@vlabel{#1}{#2}\node at ({\kmc+0.7},\dg@vy) {#3};%
}
\newcommand{\dg@vlabel}[2]{%
  \ifnum#1>1
    \ifnum#2<\kmr \pgfmathsetmacro{\dg@vy}{(2*\kmr-#1-#2+1)/2}%
    \else \pgfmathsetmacro{\dg@vy}{\kmr-#1+0.75}\fi
  \else \pgfmathsetmacro{\dg@vy}{\kmr-#2-0.25}\fi
}
\newcommand{\kmaploop}[6][]{%
  \stepcounter{dg@loop}%
  \pgfmathsetmacro{\kmi}{0.02+0.06*\thedg@loop}%
  \draw[thick, rounded corners=6pt, #1]
    ({#2-1+\kmi},{\kmr-#5+\kmi}) rectangle ({#4-\kmi},{\kmr-#3+1-\kmi});
  \def\dg@tmp{#6}\ifx\dg@tmp\@empty\else
    \xdef\dg@legend{\ifx\dg@legend\@empty\else\dg@legend,\fi{#1}/{#6}}\fi%
}

% ---- waveform: a scope-style timing diagram (from dldlab.cls), extended
% with a bus row.  One character per step: 0, 1, or for \wavebus a label
% cell where `.` continues the previous value and `x` is don't-care.
\pgfdeclarelayer{dg@bg}
\pgfsetlayers{dg@bg,main}
\newcounter{dg@waverow}
\newenvironment{waveform}[2][0.55cm]{%
  \def\wvn{#2}\setcounter{dg@waverow}{0}%
  \begin{tikzpicture}[x=#1, y=1cm, font=\small,
                      trace/.style={thick, line join=miter}]
}{%
  \begin{pgfonlayer}{dg@bg}
    \foreach \i in {0,...,\wvn}
      \draw[gray!30, very thin] (\i,0.3) -- (\i,{-0.66*\thedg@waverow-0.05});
  \end{pgfonlayer}
  \end{tikzpicture}%
}
\newcommand{\wave}[2]{%
  \stepcounter{dg@waverow}%
  \pgfmathsetmacro{\wvy}{-\thedg@waverow*0.66}%
  \node[left] at (0,{\wvy+0.18}) {#1};
  \def\wvprev{}%
  \foreach \i in {1,...,\wvn} {%
    \StrChar{#2}{\i}[\wvb]%
    \pgfmathsetmacro{\wvlev}{\wvy+\wvb*0.36}%
    \draw[trace] ({\i-1},\wvlev) -- (\i,\wvlev);
    \ifx\wvprev\empty\else
      \pgfmathsetmacro{\wvold}{\wvy+\wvprev*0.36}%
      \draw[trace] ({\i-1},\wvold) -- ({\i-1},\wvlev);
    \fi
    \global\let\wvprev\wvb}%
}
% \wavebus{label}{start/end/text, ...}: hexagon-ended value cells over steps
% start..end (counted from 0, end exclusive); text `x` shades as don't-care
\newcommand{\wavebus}[2]{%
  \stepcounter{dg@waverow}%
  \pgfmathsetmacro{\wvy}{-\thedg@waverow*0.66}%
  \node[left] at (0,{\wvy+0.18}) {#1};
  \foreach \ws/\we/\wt in {#2} {%
    \edef\wtx{\wt}\def\wdc{x}%
    \ifx\wtx\wdc
      \fill[black!12] (\ws,\wvy) -- (\ws+0.15,{\wvy+0.18}) -- (\ws,{\wvy+0.36}) --
        (\we,{\wvy+0.36}) -- (\we-0.15,{\wvy+0.18}) -- (\we,\wvy) -- cycle;
    \else
      \draw[trace] (\ws+0.15,\wvy) -- (\we-0.15,\wvy) -- (\we,{\wvy+0.18})
        -- (\we-0.15,{\wvy+0.36}) -- (\ws+0.15,{\wvy+0.36}) -- (\ws,{\wvy+0.18}) -- cycle;
      \node[font=\scriptsize] at ({(\ws+\we)/2},{\wvy+0.18}) {\wt};
    \fi}%
}
\newcommand{\wavegap}{\stepcounter{dg@waverow}}
\newcommand{\wavesteps}[1][]{%
  \stepcounter{dg@waverow}%
  \pgfmathsetmacro{\wvy}{-\thedg@waverow*0.66}%
  \foreach \i in {1,...,\wvn}
    \node[font=\scriptsize] at ({\i-0.5},{\wvy+0.3}) {\the\numexpr\i-1\relax};
  \node[left, font=\scriptsize] at (0,{\wvy+0.3}) {#1};
}

% ---- pipeline chart: the classic staircase of stages against cycles.
%  \begin{pipechart}{cycles}
%    \pipe{label}{IF,ID,EX,MEM,WB}{start}   % start cycle, counted from 1
%  \end{pipechart}
% A stage name of `*` draws a bubble (a stall) in that cycle.
\newcounter{dg@piperow}
\newenvironment{pipechart}[1]{%
  \def\pcn{#1}\setcounter{dg@piperow}{0}%
  \begin{tikzpicture}[x=1.05cm, y=0.62cm, font=\scriptsize]
  \foreach \c in {1,...,#1} \node at ({\c-0.5},0.55) {\c};
  \node[left] at (0,0.55) {cycle};
}{%
  \begin{pgfonlayer}{dg@bg}
    \foreach \c in {0,...,\pcn}
      \draw[gray!30, very thin] (\c,0.2) -- (\c,{-\thedg@piperow-0.1});
  \end{pgfonlayer}
  \end{tikzpicture}%
}
\newcommand{\pipe}[3]{%
  \stepcounter{dg@piperow}%
  \pgfmathsetmacro{\pcy}{-\thedg@piperow}%
  \node[left, font=\small] at (-0.05,{\pcy+0.5}) {#1};
  \foreach \s [count=\k] in {#2} {%
    \pgfmathsetmacro{\pcx}{#3+\k-2}%
    \def\pcs{\s}\def\pcb{*}%
    \ifx\pcs\pcb
      \draw[thick, dashed, fill=black!4] (\pcx+0.06,\pcy+0.1) rectangle (\pcx+0.94,\pcy+0.9);
    \else
      \draw[thick, fill=white] (\pcx+0.06,\pcy+0.1) rectangle (\pcx+0.94,\pcy+0.9);
      \node at (\pcx+0.5,\pcy+0.5) {\s};
    \fi}%
}

% ---- aside: a short boxed note, for "why it is built this way"
\newsavebox{\dg@asidebox}
\newenvironment{aside}{%
  \par\smallskip\noindent
  \begin{lrbox}{\dg@asidebox}\begin{minipage}{\dimexpr\linewidth-2\fboxsep-2\fboxrule-8pt\relax}\small
}{%
  \end{minipage}\end{lrbox}%
  \setlength{\fboxsep}{6pt}\setlength{\fboxrule}{0.8pt}\fbox{\usebox{\dg@asidebox}}\par\smallskip
}

% ---- \bw[pos]{x,y}{n}: a slash across a bus with its width in bits
\newcommand{\bw}[3][above]{%
  \draw[line width=0.4pt] ($(#2)+(-0.08,-0.11)$) -- ($(#2)+(0.08,0.11)$);
  \node[#1, font=\tiny, inner sep=2.5pt] at (#2) {#3};%
}

% ---- \src{file}{line}: where in the repo a thing lives
\newcommand{\src}[1]{\texttt{\small\detokenize{#1}}}
