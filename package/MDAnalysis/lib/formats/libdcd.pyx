# -*- Mode: python; tab-width: 4; indent-tabs-mode:nil; coding:utf-8 -*-
# vim: tabstop=4 expandtab shiftwidth=4 softtabstop=4 fileencoding=utf-8
#
# MDAnalysis --- https://www.mdanalysis.org
# Copyright (c) 2006-2017 The MDAnalysis Development Team and contributors
# (see the file AUTHORS for the full list of names)
#
# Released under the GNU Public Licence, v2 or any higher version
#
# Please cite your use of MDAnalysis in published work:
#
# R. J. Gowers, M. Linke, J. Barnoud, T. J. E. Reddy, M. N. Melo, S. L. Seyler,
# D. L. Dotson, J. Domanski, S. Buchoux, I. M. Kenney, and O. Beckstein.
# MDAnalysis: A Python package for the rapid analysis of molecular dynamics
# simulations. In S. Benthall and S. Rostrup editors, Proceedings of the 15th
# Python in Science Conference, pages 102-109, Austin, TX, 2016. SciPy.
# doi: 10.25080/majora-629e541a-00e
#
# N. Michaud-Agrawal, E. J. Denning, T. B. Woolf, and O. Beckstein.
# MDAnalysis: A Toolkit for the Analysis of Molecular Dynamics Simulations.
# J. Comput. Chem. 32 (2011), 2319--2327, doi:10.1002/jcc.21787
#
"""\
Low level DCD  trajectory reading - :mod:`MDAnalysis.lib.formats.libdcd`
------------------------------------------------------------------------

:mod:`libdcd` contains the class :class:`DCDFile` to read and write frames of a
DCD file. The class tries to behave similar to a normal file object.

:mod:`libdcd` contains the classes :class:`DCDFile`, which can be used to read
and write frames from and to DCD files. These classes are used internally by
MDAnalysis in :mod:`MDAnalysis.coordinates.DCD`. They behave similar to normal
file objects.

For example, one can use a :class:`DCDFile` to directly calculate mean
coordinates (where the coordinates are stored in `x` attribute of the
:class:`namedtuple` `frame`):

.. code-block:: python
   :emphasize-lines: 1,2,5

   with DCDFile("trajectory.dcd") as dcd:
       header = dcd.header
       mean = np.zeros((header['natoms'], 3))
       # iterate over trajectory
       for frame in dcd:
           mean += frame.x
   mean /= header['natoms']


Besides iteration one can also seek to arbitrary frames using the
:meth:`~DCDFile.seek` method. Note that instead of seeking to a byte-offset as
for normal Python streams, the seek and tell method of DCDFile operate on
complete trajectory frames.

.. rubric:: Acknowledgements

:mod:`libdcd` contains and is originally based on DCD reading and writing code
from VMD's `molfile`_ plugin and `catdcd`_.

.. _molfile: http://www.ks.uiuc.edu/Research/vmd/plugins/molfile/
.. _catdcd: http://www.ks.uiuc.edu/Development/MDTools/catdcd/

"""
from os import path
import numpy as np
from collections import namedtuple
import string
import sys

cimport numpy as np
from libc.stdio cimport SEEK_SET, SEEK_CUR, SEEK_END
from libc.stdint cimport uintptr_t
from libc.stdlib cimport free

np.import_array()

_whence_vals = {"FIO_SEEK_SET": SEEK_SET,
                "FIO_SEEK_CUR": SEEK_CUR,
                "FIO_SEEK_END": SEEK_END}

# Tell cython about the off_t type. It doesn't need to match exactly what is
# defined since we don't expose it to python but the cython compiler needs to
# know about it.
cdef extern from 'sys/types.h':
    ctypedef int off_t

ctypedef int fio_fd;
ctypedef off_t fio_size_t

ctypedef np.float32_t FLOAT_T
ctypedef np.float64_t DOUBLE_T
FLOAT = np.float32
DOUBLE = np.float64

cdef enum:
    FIO_READ = 0x01
    FIO_WRITE = 0x02

DCD_IS_CHARMM       = 0x01
DCD_HAS_4DIMS       = 0x02
DCD_HAS_EXTRA_BLOCK = 0x04

DCD_ERRORS = {
    0: 'Success',
    -1: 'Normal EOF',
    -2: 'DCD file does not exist',
    -3: 'Open of DCD file failed',
    -4: 'read call on DCD file failed',
    -5: 'premature EOF found in DCD file',
    -6: 'format of DCD file is wrong',
    -7: 'output file already exists',
    -8: 'malloc failed'
}

cdef extern from 'include/fastio.h':
    int fio_open(const char *filename, int mode, fio_fd *fd)
    int fio_fclose(fio_fd fd)
    fio_size_t fio_ftell(fio_fd fd)
    fio_size_t fio_fseek(fio_fd fd, fio_size_t offset, int whence)

cdef extern from 'include/readdcd.h':
    int read_dcdheader(fio_fd fd, int *natoms, int *nsets, int *istart,
                       int *nsavc, double *delta, int *nfixed, int **freeind,
                       float **fixedcoords, int *reverse_endian, int *charmm,
                       char **remarks, int *len_remarks)
    void close_dcd_read(int *freeind, float *fixedcoords)
    int read_dcdstep(fio_fd fd, int natoms, float *X, float *Y, float *Z,
                     double *unitcell, int num_fixed,
                     int first, int *indexes, float *fixedcoords,
                     int reverse_endian, int charmm)
    int read_dcdsubset(fio_fd fd, int natoms, int lowerb, int upperb,
                     float *X, float *Y, float *Z,
                     double *unitcell, int num_fixed,
                     int first, int *indexes, float *fixedcoords,
                     int reverse_endian, int charmm)
    int write_dcdheader(fio_fd fd, const char *remarks, int natoms,
                   int istart, int nsavc, double delta, int with_unitcell,
                   int charmm);
    int write_dcdstep(fio_fd fd, int curframe, int curstep,
             int natoms, const float *x, const float *y, const float *z,
             const double *unitcell, int charmm);

DCDFrame = namedtuple('DCDFrame', 'xyz unitcell')

cdef class DCDFile:
    """DCDFile(fname, mode='r')

    File like wrapper for DCD files

    This class can be similar to the normal file objects in python. The read()
    function will return a frame and all information in it instead of a single
    line. Additionally the context-manager protocol is supported as well.

    DCDFile can read typical DCD files created by e.g., CHARMM, NAMD, or LAMMPS. It
    reads raw data from the trajectory and hence interpretation of, for instance,
    different unitcell conventions or time and length units, has to be handled in
    higher level code. Reading and writing does not support fixed atoms or 4D
    coordinates.

    Parameters
    ----------
    fname : str
        The filename to open.
    mode : ('r', 'w')
        The mode in which to open the file, either 'r' read or 'w' write

    Examples
    --------
    >>> from MDAnalysis.lib.formats.libdcd import DCDFile
    >>> with DCDFile('foo.dcd') as f:
    >>>     for frame in f:
    >>>         print(frame.x)


    Notes
    -----
    DCD is not a well defined format. One consequence of this is that different
    programs like CHARMM and NAMD are using different convention to store the
    unitcell information. The :class:`DCDFile` will read the unitcell
    information as is when available. Post processing depending on the program
    this DCD file was written with is necessary. Have a look at the MDAnalysis
    DCD reader for possible post processing into a common unitcell data
    structure. You can also find more information how different programs store
    unitcell information in DCD on the `mdawiki`_ . This class can be pickled.
    The pickle will store filename, mode, current frame

    .. _mdawiki: https://github.com/MDAnalysis/mdanalysis/wiki/FileFormats#dcd
    """
    cdef fio_fd fp
    cdef readonly fname
    cdef int istart
    cdef int nsavc
    cdef double delta
    cdef int natoms
    cdef int nfixed
    cdef int *freeind
    cdef float *fixedcoords
    cdef int reverse_endian
    cdef int charmm
    cdef readonly is_periodic
    cdef remarks
    cdef str mode
    cdef readonly int ndims
    cdef readonly int n_frames
    cdef bint b_read_header
    cdef int current_frame
    cdef readonly int _firstframesize
    cdef readonly int _framesize
    cdef readonly int _header_size
    cdef int is_open
    cdef int reached_eof
    cdef int wrote_header

    def __cinit__(self, fname, mode='r'):
        self.fname = fname.encode('utf-8')
        self.natoms = 0
        self.is_open = False
        self.wrote_header = False
        self.open(mode)

    def __dealloc__(self):
        self.close()

    def __enter__(self):
        """Support context manager"""
        if not self.is_open:
            self.open(self.mode)
        return self

    def __exit__(self, exc_type, exc_val, exc_tb):
        """Support context manager"""
        self.close()
        # always propagate exceptions forward
        return False

    def __iter__(self):
        self.close()
        self.open(self.mode)
        return self

    def __next__(self):
        if self.reached_eof:
            raise StopIteration
        return self.read()

    def __len__(self):
        if not self.is_open:
            raise IOError('No file currently opened')
        return self.n_frames

    def __reduce__(self):
        return (self.__class__, (self.fname.decode(), self.mode),
                self.__getstate__())

    def __getstate__(self):
        return self.is_open, self.current_frame, self.n_frames

    def __setstate__(self, state):
        is_open = state[0]
        if not is_open:
            self.close()
            return

        current_frame = state[1]
        if current_frame < self.n_frames:
            self.seek(current_frame)
        elif current_frame == self.n_frames:
            #  cannot seek to self.n_frames (a.k.a. len(DCDFile));
            #  instead, we seek to the previous frame and read next. 
            #  which is the state of the file when we need to serialize
            #  at the end of the trajectory.
            self.seek(current_frame - 1)
            _ = self.read()
        else:             # pragma: no cover
            raise RuntimeError("Invalid frame number {} > {} -- this should"
                               "not happen.".format(current_frame,
                                                    self.n_frames)
                              )

    def tell(self):
        """
        Returns
        -------
        current frame (0-based)
        """
        return self.current_frame

    def open(self, mode='r'):
        """open(mode='r')

        Open a DCD file

        If another DCD file is currently opened it will be closed

        Parameters
        ----------
        mode : ('r', 'w')
            The mode in which to open the file, either 'r' read or 'w' write

        """
        if self.is_open:
            self.close()

        if mode == 'r':
            if not path.isfile(self.fname):
                raise IOError("DCD file does not exist")
            fio_mode = FIO_READ
        elif mode == 'w':
            fio_mode = FIO_WRITE
        else:
            raise IOError("unkown mode '{}', use either r or w".format(mode))
        self.mode = str(mode)

        ok = fio_open(self.fname, fio_mode, <fio_fd*> &self.fp)
        if ok != 0:
            raise IOError("couldn't open file: {}\n"
                          "ErrorCode: {}".format(self.fname, DCD_ERRORS[ok]))
        self.is_open = True
        self.current_frame = 0
        self.reached_eof = False
        self.wrote_header = False
        # Has to come last since it checks the reached_eof flag
        if self.mode == 'r':
            self._read_header()

    def close(self):
        """Close the open DCD file

        """
        if self.is_open:
            # In case there are fixed atoms we should free the memory again.
            # Both pointers are guaranted to be non NULL if either one is.
            if self.freeind != NULL:
                close_dcd_read(self.freeind, self.fixedcoords);

            ok = fio_fclose(self.fp)

            self.is_open = False
            if ok != 0:
                raise IOError("couldn't close file: {}\n"
                              "ErrorCode: {}".format(self.fname, DCD_ERRORS[ok]))


    cdef void _read_header(self):
        """read header and populate internal fields"""
        if not self.is_open:
            raise IOError("No file open")

        cdef char* c_remarks
        cdef int len_remarks = 0
        cdef int nsets

        ok = read_dcdheader(self.fp, &self.natoms, &nsets, &self.istart,
                            &self.nsavc, &self.delta, &self.nfixed, &self.freeind,
                            &self.fixedcoords, &self.reverse_endian,
                            &self.charmm, &c_remarks, &len_remarks)
        if ok != 0:
            raise IOError("Reading DCD header failed: {}".format(DCD_ERRORS[ok]))

        self.is_periodic = bool((self.charmm & DCD_IS_CHARMM) and
                                (self.charmm & DCD_HAS_EXTRA_BLOCK))

        if c_remarks != NULL:
            py_remarks = <bytes> c_remarks[:len_remarks]
            free(c_remarks)
        else:
            py_remarks = ""
        self.ndims = 3 if not self.charmm & DCD_HAS_4DIMS else 4
        # This function assumes that the dcd header was already read and
        # self.ndims is set. It will only work when called here !!!
        self.n_frames = self._estimate_n_frames()
        self.b_read_header = True

        # make sure fixed atoms have been read
        try:
            self.read()
            self.seek(0)
        except IOError:
            if self.n_frames != 0:
                raise IOError("DCD is corrupted")

        if sys.version_info[0] < 3:
            py_remarks = unicode(py_remarks, 'ascii', "ignore")
            py_remarks = str(py_remarks.encode('ascii', 'ignore'))
        else:
            if isinstance(py_remarks, bytes):
                py_remarks = py_remarks.decode('ascii', 'ignore')

        py_remarks = "".join(s for s in py_remarks if s in string.printable)

        self.remarks = py_remarks

    cdef int _estimate_n_frames(self):
        """ Only call this function in _read_header!!!
        """
        extrablocksize = 48 + 8 if self.charmm & DCD_HAS_EXTRA_BLOCK else 0
        self._firstframesize = (self.natoms + 2) * self.ndims * sizeof(float) + extrablocksize
        self._framesize = ((self.natoms - self.nfixed + 2) * self.ndims * sizeof(float) +
                          extrablocksize)
        filesize = path.getsize(self.fname)
        # It's safe to use ftell, even though ftell returns a long, because the
        # header size is < 4GB.
        self._header_size = fio_ftell(self.fp)
        nframessize = filesize - self._header_size - self._firstframesize
        return nframessize / self._framesize + 1

    def seek(self, frame):
        """seek(frame)

        Seek to Frame.

        Parameters
        ----------
        frame : int
            seek the file to given frame (0-based)

        """
        if frame >= self.n_frames:
            raise EOFError('Trying to seek over max number of frames')
        self.reached_eof = False

        cdef fio_size_t offset
        if frame == 0:
            offset = self._header_size
        else:
            offset = self._header_size + self._firstframesize + self._framesize * (frame - 1)

        ok = fio_fseek(self.fp, offset, _whence_vals["FIO_SEEK_SET"])
        if ok != 0:
            raise IOError("DCD seek failed with DCD error={}".format(DCD_ERRORS[ok]))
        self.current_frame = frame

    @property
    def header(self):
        """
        Returns
        -------
        dict of header values needed to write new dcd.
        natoms: number of atoms
        istart: starting frame number
        nsavc: number of frames between saves
        delta: integrator time step.
        charm: bitfield integer if file contains special CHARMM information
        remarks: remark string, max 240 bytes.


        """
        return {'natoms': self.natoms,
                'istart': self.istart,
                'nsavc': self.nsavc,
                'delta': self.delta,
                'is_periodic': self.is_periodic,
                'remarks': self.remarks}

    @property
    def charmm_bitfield(self):
        """This DCDFile reader can process files written by different MD simulation
        programs. For files produced by CHARMM or other programs that follow
        the same convention we are reading a special CHARMM bitfield that
        stores different flags about additional information that is stored in
        the dcd. The bit flags are:

        .. code::

            DCD_IS_CHARMM       = 0x01
            DCD_HAS_4DIMS       = 0x02
            DCD_HAS_EXTRA_BLOCK = 0x04

        Here `DCD_HAS_EXTRA_BLOCK` means that unitcell information is stored.

        """
        return self.charmm

    def write_header(self, remarks, natoms, istart, nsavc, delta, is_periodic):
        """write_header(remarks, natoms, istart, nsavc, delta, is_periodic)
        Write DCD header

        This function needs to be called before the first frame can be written.

        Parameters
        ----------
        remarks : str
            remarks of DCD file. Writes up to 239 characters (ASCII). The
            character 240 will be the null terminator
        natoms : int
            number of atoms to write
        istart : int
            starting frame number
        nsavc : int
            number of frames between saves
        delta : float
            integrator time step. The time for 1 frame is nsavc * delta
        is_periodic : bool
            write unitcell information. Also pretends that file was written by CHARMM 24

        """
        if not self.is_open:
            raise IOError("No file open")
        if not self.mode=='w':
            raise IOError("Incorrect file mode for writing.")
        if self.wrote_header:
            raise IOError("Header already written")

        cdef int with_unitcell = is_periodic
        if is_periodic:
            self.charmm = DCD_HAS_EXTRA_BLOCK | DCD_IS_CHARMM
        self.natoms = natoms

        if isinstance(remarks, str):
            try:
                remarks = bytearray(remarks, 'ascii')
            except UnicodeDecodeError:
                remarks = bytearray(remarks)

        ok = write_dcdheader(self.fp, remarks, self.natoms, istart,
                             nsavc, delta, with_unitcell,
                             self.charmm)
        if ok != 0:
            raise IOError("Writing DCD header failed: {}".format(DCD_ERRORS[ok]))
        self.wrote_header = True

    def write(self, xyz,  box=None):
        """write(xyz, box=None)
        write one frame into DCD file.

        Parameters
        ----------
        xyz : array_like, shape=(natoms, 3)
            cartesion coordinates
        box : array_like, shape=(6) (optional)
            Box vectors for this frame. Can be left to skip writing a unitcell

        """
        if not self.is_open:
            raise IOError("No file open")
        if self.mode != 'w':
            raise IOError('File opened in mode: {}. Writing only allowed '
                          'in mode "w"'.format('self.mode'))
        if (self.charmm & DCD_HAS_EXTRA_BLOCK):
            if len(box) != 6:
                raise ValueError("box size is wrong should be 6, got: {}".format(box.size))
        else:
            # use a dummy box. It won't be written anyway in readdcd.
            box = np.zeros(6)

        if not self.wrote_header:
            raise IOError("write header first before frames can be written")
        xyz = np.asarray(xyz, order='F', dtype=FLOAT)
        if xyz.shape != (self.natoms, 3):
            raise ValueError("xyz shape is wrong should be (natoms, 3), got:".format(xyz.shape))

        cdef DOUBLE_T[::1] c_box = np.asarray(box, order='C', dtype=DOUBLE)
        cdef FLOAT_T[::1] x = xyz[:, 0]
        cdef FLOAT_T[::1] y = xyz[:, 1]
        cdef FLOAT_T[::1] z = xyz[:, 2]

        step = self.istart + self.current_frame * self.nsavc
        ok = write_dcdstep(self.fp, self.current_frame + 1, step,
                           self.natoms, <FLOAT_T*> &x[0],
                           <FLOAT_T*> &y[0], <FLOAT_T*> &z[0],
                           <DOUBLE_T*> &c_box[0], self.charmm)
        if ok != 0:
            raise IOError("Couldn't write DCD frame: reason {}".format(DCD_ERRORS[ok]))

        self.current_frame += 1

    def read(self):
        """
        Read next dcd frame

        Returns
        -------
        DCDFrame : namedtuple
            positions are in ``x`` and unitcell in ``unitcell`` attribute of DCDFrame

        Notes
        -----
        unitcell is read as is from DCD. Post processing depending on the program this
        DCD file was written with is necessary. Have a look at the MDAnalysis DCD reader
        for possible post processing into a common unitcell data structure.

        """
        if self.reached_eof:
            raise EOFError('Reached last frame in DCD, seek to 0')
        if not self.is_open:
            raise IOError("No file open")
        if self.mode != 'r':
            raise IOError('File opened in mode: {}. Reading only allow '
                               'in mode "r"'.format('self.mode'))
        if self.n_frames == 0:
            raise IOError("opened empty file. No frames are saved")

        cdef np.ndarray xyz = np.empty((self.natoms, self.ndims), dtype=FLOAT, order='F')
        cdef np.ndarray unitcell = np.empty(6, dtype=DOUBLE)
        unitcell[0] = unitcell[2] = unitcell[5] = 0.0;
        unitcell[4] = unitcell[3] = unitcell[1] = 90.0;

        first_frame = self.current_frame == 0
        ok = self.c_readframes_helper(xyz[:, 0], xyz[:, 1], xyz[:, 2], unitcell, first_frame)
        if ok != 0 and ok != -4:
            raise IOError("Reading DCD header failed: {}".format(DCD_ERRORS[ok]))

        # we couldn't read any more frames.
        if ok == -4:
            self.reached_eof = True
            raise StopIteration

        self.current_frame += 1
        return DCDFrame(xyz, unitcell)


    def readframes(self, start=None, stop=None, step=None, order='fac', indices=None):
        """readframes(start=None, stop=None, step=None, order='fac', indices=None)
        read multiple frames at once

        Parameters
        ----------
        start : int (optional)
            starting frame, default to 0
        stop : int (optional)
            stop frame, default to ``n_frames``
        step : int (optional)
            step between frames read, defaults to 1
        order : str (optional)
            give order of returned array with `f`:frames, `a`:atoms, `c`:coordinates
        indices : array_like (optional)
            only read selected atoms. In ``None`` read all.

        Returns
        -------
        DCDFrame : namedtuple
            positions are in ``x`` and unitcell in ``unitcell`` attribute of DCDFrame.
            Here the attributes contain the positions for all frames in the given order

        Notes
        -----
        unitcell is read as it from DCD. Post processing depending the program
        this DCD file was written with is necessary. Have a look at the
        MDAnalysis DCD reader for possible post processing into a common
        unitcell data structure.

        """
        if self.reached_eof:
            raise EOFError('Reached last frame in DCD, seek to 0')
        if not self.is_open:
            raise IOError("No file open")
        if self.mode != 'r':
            raise IOError('File opened in mode: {}. Reading only allow '
                               'in mode "r"'.format('self.mode'))
        if self.n_frames == 0:
            raise IOError("opened empty file. No frames are saved")

        self.seek(0)
        # if we only want to iterate backwards flip start and end
        if start is None and stop is None and step is not None and step < 0:
            stop = -1
            start = self.n_frames - 1
        stop = stop if not stop is None else self.n_frames
        start = start if not start is None else 0
        step = step if not step is None else 1


        cdef int n
        n = len(range(start, stop, step))

        cdef np.ndarray[np.int64_t, ndim=1] c_indices
        if indices is None:
            c_indices = np.arange(self.natoms, dtype=np.int64)
            natoms = self.natoms
        else:
            natoms = len(indices)
            c_indices = np.asarray(indices, dtype=np.int64)

        cdef int hash_order = -1
        if order == 'fac':
            shape = (n, natoms, self.ndims)
            hash_order = 1
        elif order == 'fca':
            shape = (n, self.ndims, natoms)
            hash_order = 2
        elif order == 'afc':
            shape = (natoms, n, self.ndims)
            hash_order = 3
        elif order == 'acf':
            shape = (natoms, self.ndims, n)
            hash_order = 4
        elif order == 'caf':
            shape = (self.ndims, natoms, n)
            hash_order = 5
        elif order == 'cfa':
            hash_order = 6
            shape = (self.ndims, n, natoms)
        else:
            raise ValueError("unkown order '{}'".format(order))

        cdef np.ndarray[FLOAT_T, ndim=3] xyz = np.empty(shape, dtype=FLOAT)
        cdef np.ndarray[DOUBLE_T, ndim=2] box = np.empty((n, 6))


        cdef np.ndarray xyz_tmp = np.empty((self.natoms, self.ndims), dtype=FLOAT, order='F')
        cdef int ok, i

        if start == 0 and step == 1 and stop == self.n_frames:
            for i in range(n):
                ok = self.c_readframes_helper(xyz_tmp[:, 0], xyz_tmp[:, 1], xyz_tmp[:, 2], box[i], i==0)
                if ok != 0 and ok != -4:
                    raise IOError("Reading DCD frames failed: {}".format(DCD_ERRORS[ok]))
                copy_in_order(xyz_tmp[c_indices], xyz, hash_order, i)
        else:
            counter = 0
            for i in range(start, stop, step):
                self.seek(i)
                ok = self.c_readframes_helper(xyz_tmp[:, 0], xyz_tmp[:, 1], xyz_tmp[:, 2], box[counter], i==0)
                if ok != 0 and ok != -4:
                    raise IOError("Reading DCD frames failed: {}".format(DCD_ERRORS[ok]))
                copy_in_order(xyz_tmp[c_indices], xyz, hash_order, counter)
                counter += 1

        return DCDFrame(xyz, box)

    # Helper to read current DCD frame
    cdef int c_readframes_helper(self, FLOAT_T[::1] x,
                                 FLOAT_T[::1] y, FLOAT_T[::1] z,
                                 DOUBLE_T[::1] unitcell, int first_frame):
        cdef int ok
        ok = read_dcdstep(self.fp, self.natoms,
                          <FLOAT_T*> &x[0],
                          <FLOAT_T*> &y[0], <FLOAT_T*> &z[0],
                          <DOUBLE_T*> &unitcell[0], self.nfixed, first_frame,
                          self.freeind, self.fixedcoords,
                          self.reverse_endian, self.charmm)
        return ok


# Helper in readframes to copy given a specific memory layout
cdef void copy_in_order(FLOAT_T[:, :] source, FLOAT_T[:, :, :] target, int order, int index):
    if order == 1:  #  'fac':
        target[index] = source
    elif order == 2:  #  'fca':
        target[index] = source.T
    elif order == 3:  # 'afc':
        target[:, index] = source
    elif order == 4:  # 'acf':
        target[:, :, index] = source
    elif order == 5:  # 'caf':
        target[:, :, index] = source.T
    elif order == 6:  # 'cfa':
        target[:, index] = source.T
