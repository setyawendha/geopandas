import collections
import numbers

import shapely
from shapely.geometry import MultiPoint, MultiLineString, MultiPolygon
from shapely.geometry.base import BaseGeometry, geom_factory
from shapely.ops import cascaded_union, unary_union
import shapely.affinity as affinity

import cython
cimport cpython.array

cimport numpy as np
import numpy as np
import pandas as pd
from pandas import Series, DataFrame, MultiIndex

import geopandas as gpd

from .base import GeoPandasBase

include "_geos.pxi"

from shapely.geometry.base import (GEOMETRY_TYPES as GEOMETRY_NAMES, CAP_STYLE,
        JOIN_STYLE)

GEOMETRY_TYPES = [getattr(shapely.geometry, name) for name in GEOMETRY_NAMES]


cdef get_element(np.ndarray[np.uintp_t, ndim=1, cast=True] geoms, int idx):
    cdef GEOSGeometry *geom
    cdef GEOSContextHandle_t handle
    geom = <GEOSGeometry *> geoms[idx]

    handle = get_geos_context_handle()
    geom = GEOSGeom_clone_r(handle, geom)  # create a copy rather than deal with gc
    typ = GEOMETRY_TYPES[GEOSGeomTypeId_r(handle, geom)]

    return geom_factory(<np.uintp_t> geom)


@cython.boundscheck(False)
@cython.wraparound(False)
cpdef points_from_xy(np.ndarray[double, ndim=1, cast=True] x,
                     np.ndarray[double, ndim=1, cast=True] y):
    cdef Py_ssize_t idx
    cdef GEOSContextHandle_t handle
    cdef GEOSCoordSequence *sequence
    cdef GEOSGeometry *geom
    cdef uintptr_t geos_geom
    cdef unsigned int n = x.size

    cdef np.ndarray[np.uintp_t, ndim=1] out = np.empty(n, dtype=np.uintp)

    handle = get_geos_context_handle()

    with nogil:
        for idx in xrange(n):
            sequence = GEOSCoordSeq_create_r(handle, 1, 2)
            GEOSCoordSeq_setX_r(handle, sequence, 0, x[idx])
            GEOSCoordSeq_setY_r(handle, sequence, 0, y[idx])
            geom = GEOSGeom_createPoint_r(handle, sequence)
            geos_geom = <np.uintp_t> geom
            out[idx] = <np.uintp_t> geom

    return VectorizedGeometry(out)


@cython.boundscheck(False)
@cython.wraparound(False)
cdef prepared_binary_predicate(str op,
                               np.ndarray[np.uintp_t, ndim=1, cast=True] geoms,
                               object other):
    cdef Py_ssize_t idx
    cdef GEOSContextHandle_t handle
    cdef GEOSGeometry *geom
    cdef GEOSGeometry *other_geom
    cdef GEOSPreparedGeometry *prepared_geom
    cdef unsigned int n = geoms.size

    cdef np.ndarray[np.uint8_t, ndim=1, cast=True] out = np.empty(n, dtype=np.bool_)

    handle = get_geos_context_handle()
    other_geom = <GEOSGeometry *> other.__geom__

    # Prepare the geometry if it hasn't already been prepared.
    # TODO: why can't we do the following instead?
    #   prepared_geom = GEOSPrepare_r(handle, other_geom)
    if not isinstance(other, shapely.prepared.PreparedGeometry):
        other = shapely.prepared.prep(other)

    geos_handle = get_geos_context_handle()
    prepared_geom = geos_from_prepared(other)

    if op == 'contains':
        func = GEOSPreparedContains_r
    elif op == 'disjoint':
        func = GEOSPreparedDisjoint_r
    elif op == 'intersects':
        func = GEOSPreparedIntersects_r
    elif op == 'touches':
        func = GEOSPreparedTouches_r
    elif op == 'crosses':
        func = GEOSPreparedCrosses_r
    elif op == 'within':
        func = GEOSPreparedWithin_r
    elif op == 'contains_properly':
        func = GEOSPreparedContainsProperly_r
    elif op == 'overlaps':
        func = GEOSPreparedOverlaps_r
    elif op == 'covers':
        func = GEOSPreparedCovers_r
    elif op == 'covered_by':
        func = GEOSPreparedCoveredBy_r
    else:
        raise NotImplementedError(op)

    with nogil:
        for idx in xrange(n):
            geom = <GEOSGeometry *> geoms[idx]
            out[idx] = func(handle, prepared_geom, geom)

    return out


@cython.boundscheck(False)
@cython.wraparound(False)
cdef vector_binary_predicate(str op,
                             np.ndarray[np.uintp_t, ndim=1, cast=True] left,
                             np.ndarray[np.uintp_t, ndim=1, cast=True] right):
    cdef Py_ssize_t idx
    cdef GEOSContextHandle_t handle
    cdef GEOSGeometry *left_geom
    cdef GEOSGeometry *right_geom
    cdef unsigned int n = left.size

    cdef np.ndarray[np.uint8_t, ndim=1, cast=True] out = np.empty(n, dtype=np.bool_)

    handle = get_geos_context_handle()

    if op == 'contains':
        func = GEOSContains_r
    elif op == 'disjoint':
        func = GEOSDisjoint_r
    elif op == 'equals':
        func = GEOSEquals_r
    elif op == 'intersects':
        func = GEOSIntersects_r
    elif op == 'touches':
        func = GEOSTouches_r
    elif op == 'crosses':
        func = GEOSCrosses_r
    elif op == 'within':
        func = GEOSWithin_r
    elif op == 'overlaps':
        func = GEOSOverlaps_r
    elif op == 'covers':
        func = GEOSCovers_r
    elif op == 'covered_by':
        func = GEOSCoveredBy_r
    else:
        raise NotImplementedError(op)

    with nogil:
        for idx in xrange(n):
            left_geom = <GEOSGeometry *> left[idx]
            right_geom = <GEOSGeometry *> right[idx]
            out[idx] = func(handle, left_geom, right_geom)

    return out


@cython.boundscheck(False)
@cython.wraparound(False)
cdef binary_predicate(str op,
                      np.ndarray[np.uintp_t, ndim=1, cast=True] geoms,
                      object other):
    cdef Py_ssize_t idx
    cdef GEOSContextHandle_t handle
    cdef GEOSGeometry *geom
    cdef GEOSGeometry *other_geom
    cdef uintptr_t other_pointer
    cdef unsigned int n = geoms.size

    cdef np.ndarray[np.uint8_t, ndim=1, cast=True] out = np.empty(n, dtype=np.bool_)

    handle = get_geos_context_handle()
    other_pointer = <np.uintp_t> other.__geom__
    other_geom = <GEOSGeometry *> other_pointer


    if op == 'contains':
        func = GEOSContains_r
    elif op == 'disjoint':
        func = GEOSDisjoint_r
    elif op == 'equals':
        func = GEOSEquals_r
    elif op == 'intersects':
        func = GEOSIntersects_r
    elif op == 'touches':
        func = GEOSTouches_r
    elif op == 'crosses':
        func = GEOSCrosses_r
    elif op == 'within':
        func = GEOSWithin_r
    elif op == 'overlaps':
        func = GEOSOverlaps_r
    elif op == 'covers':
        func = GEOSCovers_r
    elif op == 'covered_by':
        func = GEOSCoveredBy_r

    with nogil:
        for idx in xrange(n):
            geom = <GEOSGeometry *> geoms[idx]
            out[idx] = func(handle, geom, other_geom)

    return out


@cython.boundscheck(False)
@cython.wraparound(False)
cdef geo_unary_op(str op, np.ndarray[np.uintp_t, ndim=1, cast=True] geoms):
    cdef Py_ssize_t idx
    cdef GEOSContextHandle_t handle
    cdef GEOSGeometry *geom
    cdef uintptr_t geos_geom
    cdef GEOSGeometry *other_geom
    cdef unsigned int n = geoms.size

    cdef np.ndarray[np.uintp_t, ndim=1, cast=True] out = np.empty(n, dtype=np.uintp)

    handle = get_geos_context_handle()

    if op == 'boundary':
        func = GEOSBoundary_r
    elif op == 'centroid':
        func = GEOSGetCentroid_r
    elif op == 'convex_hull':
        func = GEOSConvexHull_r
    # elif op == 'exterior':
    #     func = GEOSGetExteriorRing_r  # segfaults on cleanup?
    elif op == 'envelope':
        func = GEOSEnvelope_r
    elif op == 'representative_point':
        func = GEOSPointOnSurface_r
    else:
        raise NotImplementedError("Op %s not known" % op)

    with nogil:
        for idx in xrange(n):
            geos_geom = geoms[idx]
            geom = <GEOSGeometry *> geos_geom
            out[idx] = <np.uintp_t> func(handle, geom)

    return VectorizedGeometry(out)


@cython.boundscheck(False)
@cython.wraparound(False)
cdef buffer(np.ndarray[np.uintp_t, ndim=1, cast=True] geoms, double distance,
            int resolution, int cap_style, int join_style, double mitre_limit):
    cdef Py_ssize_t idx
    cdef GEOSContextHandle_t handle
    cdef GEOSGeometry *geom
    cdef uintptr_t geos_geom
    cdef GEOSGeometry *other_geom
    cdef unsigned int n = geoms.size

    cdef np.ndarray[np.uintp_t, ndim=1, cast=True] out = np.empty(n, dtype=np.uintp)
    handle = get_geos_context_handle()

    with nogil:
        for idx in xrange(n):
            geos_geom = geoms[idx]
            geom = <GEOSGeometry *> geos_geom
            out[idx] = <np.uintp_t> GEOSBufferWithStyle_r(handle, geom,
                    distance, resolution, cap_style, join_style, mitre_limit)

    return VectorizedGeometry(out)



@cython.boundscheck(False)
@cython.wraparound(False)
cdef get_coordinate_point(np.ndarray[np.uintp_t, ndim=1, cast=True] geoms,
                          int coordinate):
    cdef Py_ssize_t idx
    cdef GEOSContextHandle_t handle
    cdef GEOSGeometry *geom
    cdef GEOSCoordSequence *sequence
    cdef unsigned int n = geoms.size
    cdef double value

    cdef np.ndarray[double, ndim=1, cast=True] out = np.empty(n, dtype=np.float)

    handle = get_geos_context_handle()

    if coordinate == 0:
        func = GEOSCoordSeq_getX_r
    elif coordinate == 1:
        func = GEOSCoordSeq_getY_r
    elif coordinate == 2:
        func = GEOSCoordSeq_getZ_r
    else:
        raise NotImplementedError("Coordinate must be between 0-x, 1-y, 2-z")

    with nogil:
        for idx in xrange(n):
            geom = <GEOSGeometry *> geoms[idx]
            sequence = GEOSGeom_getCoordSeq_r(handle, geom)
            func(handle, sequence, 0, &value)
            out[idx] = value

    return out


cpdef from_shapely(object L):
    cdef Py_ssize_t idx
    cdef GEOSContextHandle_t handle
    cdef GEOSGeometry *geom
    cdef uintptr_t geos_geom
    cdef unsigned int n

    n = len(L)

    cdef np.ndarray[np.uintp_t, ndim=1] out = np.empty(n, dtype=np.uintp)

    handle = get_geos_context_handle()

    for idx in xrange(n):
        g = L[idx]
        geos_geom = <np.uintp_t> g.__geom__
        geom = GEOSGeom_clone_r(handle, <GEOSGeometry *> geos_geom)  # create a copy rather than deal with gc
        out[idx] = <np.uintp_t> geom

    return VectorizedGeometry(out)


@cython.boundscheck(False)
@cython.wraparound(False)
cdef free(np.ndarray[np.uintp_t, ndim=1, cast=True] geoms):
    cdef Py_ssize_t idx
    cdef GEOSContextHandle_t handle
    cdef GEOSGeometry *geom
    cdef uintptr_t geos_geom
    cdef unsigned int n = geoms.size

    handle = get_geos_context_handle()

    with nogil:
        for idx in xrange(n):
            geos_geom = geoms[idx]
            geom = <GEOSGeometry *> geos_geom
            GEOSGeom_destroy_r(handle, geom)


class VectorizedGeometry(object):
    def __init__(self, data, parent=None):
        self.data = data
        self.parent = parent

    def __getitem__(self, idx):
        if isinstance(idx, numbers.Integral):
            return get_element(self.data, idx)
        elif isinstance(idx, (collections.Iterable, slice)):
            return VectorizedGeometry(self.data[idx], parent=self)
        else:
            raise TypeError("Index type not supported", idx)

    def __len__(self):
        return len(self.data)

    def __del__(self):
        if self.parent is None:
            free(self.data)

    @property
    def x(self):
        return get_coordinate_point(self.data, 0)

    @property
    def y(self):
        return get_coordinate_point(self.data, 1)

    def binop_predicate(self, other, op):
        if isinstance(other, BaseGeometry):
            return binary_predicate(op, self.data, other)
        elif isinstance(other, VectorizedGeometry):
            assert len(self) == len(other)
            return vector_binary_predicate(op, self.data, other.data)
        else:
            raise NotImplementedError("type not known %s" % type(other))

    def covers(self, other):
        return self.binop_predicate(other, 'covers')

    def contains(self, other):
        return self.binop_predicate(other, 'contains')

    def crosses(self, other):
        return self.binop_predicate(other, 'crosses')

    def disjoint(self, other):
        return self.binop_predicate(other, 'disjoint')

    def equals(self, other):
        return self.binop_predicate(other, 'equals')

    def intersects(self, other):
        return self.binop_predicate(other, 'intersects')

    def overlaps(self, other):
        return self.binop_predicate(other, 'overlaps')

    def touches(self, other):
        return self.binop_predicate(other, 'touches')

    def within(self, other):
        return self.binop_predicate(other, 'within')

    def equals_exact(self, other):
        return prepared_binary_predicate('', self.data, other)

    def rcontains(self, other):
        return prepared_binary_predicate('contains', self.data, other)

    def rcovers(self, other):
        return prepared_binary_predicate('covers', self, other)

    def rcovered_by(self, other):
        return prepared_binary_predicate('covered_by', self, other)

    def rcrosses(self, other):
        return prepared_binary_predicate('crosses', self.data, other)

    def rdisjoint(self, other):
        return prepared_binary_predicate('crosses', self.data, other)

    def rintersects(self, other):
        return prepared_binary_predicate('intersects', self.data, other)

    def roverlaps(self, other):
        return prepared_binary_predicate('overlaps', self.data, other)

    def rtouches(self, other):
        return prepared_binary_predicate('touches', self.data, other)

    def rwithin(self, other):
        return prepared_binary_predicate('within', self.data, other)

    def boundary(self):
        return geo_unary_op('boundary', self.data)

    def centroid(self):
        return geo_unary_op('centroid', self.data)

    def convex_hull(self):
        return geo_unary_op('convex_hull', self.data)

    def envelope(self):
        return geo_unary_op('envelope', self.data)

    def representative_point(self):
        return geo_unary_op('representative_point', self.data)

    def buffer(self, distance, resolution=16, cap_style=CAP_STYLE.round,
              join_style=JOIN_STYLE.round, mitre_limit=5.0):
        return buffer(self.data, distance, resolution, cap_style, join_style,
                      mitre_limit)