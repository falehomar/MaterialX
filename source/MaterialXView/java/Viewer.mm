//
// Copyright Contributors to the MaterialX Project
// SPDX-License-Identifier: Apache-2.0
//

#include "Viewer.h"

#ifdef MATERIALXVIEW_METAL_BACKEND
#include "RenderPipelineMetal.h"
#include <MaterialXGenMsl/MslShaderGenerator.h>
#include <MaterialXRenderMsl/MslMaterial.h>
#endif

#include <MaterialXRender/ShaderRenderer.h>
#include <MaterialXRender/CgltfLoader.h>
#include <MaterialXRender/Harmonics.h>
#include <MaterialXRender/OiioImageLoader.h>
#include <MaterialXRender/StbImageLoader.h>
#include <MaterialXRender/TinyObjLoader.h>

#include <MaterialXGenShader/DefaultColorManagementSystem.h>
#include <MaterialXGenShader/ShaderTranslator.h>
#ifdef MATERIALX_BUILD_OCIO
#include <MaterialXGenShader/OcioColorManagementSystem.h>
#endif

#if MATERIALX_BUILD_GEN_MDL
#include <MaterialXGenMdl/MdlShaderGenerator.h>
#endif
#if MATERIALX_BUILD_GEN_OSL
#include <MaterialXGenOsl/OslShaderGenerator.h>
#endif

#include <MaterialXFormat/Environ.h>
#include <MaterialXFormat/Util.h>

#include <fstream>
#include <iostream>
#include <iomanip>
#include <limits>

const mx::Vector3 DEFAULT_CAMERA_POSITION(0.0f, 0.0f, 5.0f);
const float DEFAULT_CAMERA_VIEW_ANGLE = 45.0f;
const float DEFAULT_CAMERA_ZOOM = 1.0f;

namespace
{
const bool USE_FLOAT_BUFFER = true;
const int SHADOW_MAP_SIZE = 2048;
const int ALBEDO_TABLE_SIZE = 128;
const int IRRADIANCE_MAP_WIDTH = 256;
const int IRRADIANCE_MAP_HEIGHT = 128;

const std::string DIR_LIGHT_NODE_CATEGORY = "directional_light";
const std::string IRRADIANCE_MAP_FOLDER = "irradiance";
const float ORTHO_VIEW_DISTANCE = 1000.0f;
const float ORTHO_PROJECTION_HEIGHT = 1.8f;

const float ENV_MAP_SPLIT_RADIANCE = 16.0f;
const float MAX_ENV_TEXEL_RADIANCE = 100000.0f;
const float IDEAL_ENV_MAP_RADIANCE = 6.0f;
const float IDEAL_MESH_SPHERE_RADIUS = 2.0f;
const float PI = std::acos(-1.0f);
const std::string UDIM_SEPARATORS = "._";

void applyModifiers(mx::DocumentPtr doc, const DocumentModifiers& modifiers)
{
    for (mx::ElementPtr elem : doc->traverseTree())
    {
        if (modifiers.remapElements.count(elem->getCategory()))
        {
            elem->setCategory(modifiers.remapElements.at(elem->getCategory()));
        }
        if (modifiers.remapElements.count(elem->getName()))
        {
            elem->setName(modifiers.remapElements.at(elem->getName()));
        }
        mx::StringVec attrNames = elem->getAttributeNames();
        for (const std::string& attrName : attrNames)
        {
            if (modifiers.remapElements.count(elem->getAttribute(attrName)))
            {
                elem->setAttribute(attrName, modifiers.remapElements.at(elem->getAttribute(attrName)));
            }
        }
        if (elem->hasFilePrefix() && !modifiers.filePrefixTerminator.empty())
        {
            std::string filePrefix = elem->getFilePrefix();
            if (!mx::stringEndsWith(filePrefix, modifiers.filePrefixTerminator))
            {
                elem->setFilePrefix(filePrefix + modifiers.filePrefixTerminator);
            }
        }
        mx::ElementVec children = elem->getChildren();
        for (mx::ElementPtr child : children)
        {
            if (modifiers.skipElements.count(child->getCategory()) ||
                modifiers.skipElements.count(child->getName()))
            {
                elem->removeChild(child->getName());
            }
        }
    }

    for (mx::ElementPtr elem : doc->traverseTree())
    {
        mx::NodePtr node = elem->asA<mx::Node>();
        if (node && node->getCategory() == "texcoord")
        {
            mx::InputPtr index = node->getInput("index");
            mx::ValuePtr value = index ? index->getValue() : nullptr;
            if (value && value->isA<int>() && value->asA<int>() != 0)
            {
                index->setValue(0);
            }
        }
    }
}

} // anonymous namespace

Viewer::Viewer(const std::string& materialFilename,
               const std::string& meshFilename,
               const std::string& envRadianceFilename,
               const mx::FileSearchPath& searchPath,
               const mx::FilePathVec& libraryFolders,
               int screenWidth,
               int screenHeight,
               const mx::Color3& screenColor) :
    _materialFilename(materialFilename),
    _meshFilename(meshFilename),
    _envRadianceFilename(envRadianceFilename),
    _searchPath(searchPath),
    _libraryFolders(libraryFolders),
    _meshScale(1.0f),
    _turntableEnabled(false),
    _turntableSteps(360),
    _turntableStep(0),
    _cameraPosition(DEFAULT_CAMERA_POSITION),
    _cameraUp(0.0f, 1.0f, 0.0f),
    _cameraViewAngle(DEFAULT_CAMERA_VIEW_ANGLE),
    _cameraNearDist(0.05f),
    _cameraFarDist(5000.0f),
    _cameraZoom(DEFAULT_CAMERA_ZOOM),
    _userCameraEnabled(true),
    _userTranslationActive(false),
    _lightRotation(0.0f),
    _normalizeEnvironment(false),
    _splitDirectLight(false),
    _generateReferenceIrradiance(false),
    _saveGeneratedLights(false),
    _shadowSoftness(1),
    _ambientOcclusionGain(0.6f),
    _selectedGeom(0),
    _selectedMaterial(0),
    _identityCamera(mx::Camera::create()),
    _viewCamera(mx::Camera::create()),
    _envCamera(mx::Camera::create()),
    _shadowCamera(mx::Camera::create()),
    _lightHandler(mx::LightHandler::create()),
    _typeSystem(mx::TypeSystem::create()),
    _genContext(mx::MslShaderGenerator::create(_typeSystem)),
    _unitRegistry(mx::UnitConverterRegistry::create()),
    _drawEnvironment(false),
    _outlineSelection(false),
    _renderTransparency(true),
    _renderDoubleSided(true),
    _colorTexture(nullptr),
    _splitByUdims(true),
    _mergeMaterials(false),
    _showAllInputs(false),
    _flattenSubgraphs(false),
    _targetShader("standard_surface"),
    _captureRequested(false),
    _exitRequested(false),
    _wedgeRequested(false),
    _wedgePropertyName("base"),
    _wedgePropertyMin(0.0f),
    _wedgePropertyMax(1.0f),
    _wedgeImageCount(8),
    _bakeHdr(false),
    _bakeAverage(false),
    _bakeOptimize(true),
    _bakeRequested(false),
    _bakeWidth(0),
    _bakeHeight(0),
    _bakeDocumentPerMaterial(false),
    _frameTiming(false),
    _avgFrameTime(0.0),
    _renderSimpleCube(false)
{
    mx::FileSearchPath localSearchPath = searchPath;
    localSearchPath.append(mx::FilePath::getCurrentPath());
    _materialFilename = localSearchPath.find(_materialFilename);
    _meshFilename = localSearchPath.find(_meshFilename);
    _envRadianceFilename = localSearchPath.find(_envRadianceFilename);

    set_background(mx::Color4(screenColor[0], screenColor[1], screenColor[2], 1.0f));

    _genContext.getOptions().targetColorSpaceOverride = "lin_rec709";
    _genContext.getOptions().fileTextureVerticalFlip = true;
    _genContext.getOptions().hwShadowMap = true;
    _genContext.getOptions().hwImplicitBitangents = false;

    _renderPipeline = MetalRenderPipeline::create(this);
    m_size = mx::Vector2(screenWidth, screenHeight);
    m_pixel_ratio = 1.0f;
}

void Viewer::initialize()
{
    loadStandardLibraries();

    _imageHandler = _renderPipeline->createImageHandler();
    _imageHandler->setSearchPath(_searchPath);

    mx::TinyObjLoaderPtr objLoader = mx::TinyObjLoader::create();
    mx::CgltfLoaderPtr gltfLoader = mx::CgltfLoader::create();
    _geometryHandler = mx::GeometryHandler::create();
    _geometryHandler->addLoader(objLoader);
    _geometryHandler->addLoader(gltfLoader);
    
    mx::FilePath resolvedMesh = _searchPath.find(_meshFilename);
    std::cout << "[MaterialX Viewer LOG] Resolving mesh filename: " << _meshFilename.asString() << " -> resolved path: " << resolvedMesh.asString() << std::endl;
    if (resolvedMesh.isEmpty() || !resolvedMesh.exists())
    {
        std::cerr << "[MaterialX Viewer ERROR] Mesh file does not exist or cannot be resolved: " << _meshFilename.asString() << std::endl;
    }
    loadMesh(resolvedMesh);

    _renderPipeline->initFramebuffer(m_size[0], m_size[1], nullptr);
    
    _envGeometryHandler = mx::GeometryHandler::create();
    _envGeometryHandler->addLoader(objLoader);
    mx::FilePath envSphere("resources/Geometry/sphere.obj");
    mx::FilePath resolvedSphere = _searchPath.find(envSphere);
    std::cout << "[MaterialX Viewer LOG] Resolving environment sphere obj: " << envSphere.asString() << " -> resolved path: " << resolvedSphere.asString() << std::endl;
    if (resolvedSphere.isEmpty() || !resolvedSphere.exists())
    {
        std::cerr << "[MaterialX Viewer ERROR] Environment sphere OBJ file does not exist: " << envSphere.asString() << std::endl;
    }
    _envGeometryHandler->loadGeometry(resolvedSphere);

    loadEnvironmentLight();
    initCamera();
    updateGeometrySelections();

    mx::FilePath resolvedDoc = _searchPath.find(_materialFilename);
    std::cout << "[MaterialX Viewer LOG] Resolving material document: " << _materialFilename.asString() << " -> resolved path: " << resolvedDoc.asString() << std::endl;
    if (resolvedDoc.isEmpty() || !resolvedDoc.exists())
    {
        std::cerr << "[MaterialX Viewer ERROR] Material document file does not exist: " << _materialFilename.asString() << std::endl;
    }
    loadDocument(resolvedDoc, _stdLib);
    _turntableTimer.startTimer();
}

void Viewer::loadEnvironmentLight()
{
    mx::FilePath resolvedEnv = _searchPath.find(_envRadianceFilename);
    std::cout << "[MaterialX Viewer LOG] Resolving environment light: " << _envRadianceFilename.asString() << " -> resolved path: " << resolvedEnv.asString() << std::endl;
    mx::ImagePtr envRadianceMap = _imageHandler->acquireImage(resolvedEnv);
    if (!envRadianceMap)
    {
        std::cerr << "[MaterialX Viewer ERROR] Failed to load environment light image: " << _envRadianceFilename.asString() << std::endl;
        return;
    }

    if (_normalizeEnvironment)
    {
        envRadianceMap = mx::normalizeEnvironment(envRadianceMap, IDEAL_ENV_MAP_RADIANCE, MAX_ENV_TEXEL_RADIANCE);
    }

    if (_splitDirectLight)
    {
        splitDirectLight(envRadianceMap, envRadianceMap, _lightRigDoc);
    }

    mx::ImagePtr envIrradianceMap;
    if (!_normalizeEnvironment && !_splitDirectLight)
    {
        mx::FilePath envIrradiancePath = _envRadianceFilename.getParentPath() / IRRADIANCE_MAP_FOLDER / _envRadianceFilename.getBaseName();
        envIrradianceMap = _imageHandler->acquireImage(envIrradiancePath);
    }

    if (!envIrradianceMap || envIrradianceMap->getWidth() == 1)
    {
        mx::Sh3ColorCoeffs shIrradiance = mx::projectEnvironment(envRadianceMap, true);
        envIrradianceMap = mx::renderEnvironment(shIrradiance, IRRADIANCE_MAP_WIDTH, IRRADIANCE_MAP_HEIGHT);
    }

    _imageHandler->releaseRenderResources(_lightHandler->getEnvRadianceMap());
    _imageHandler->releaseRenderResources(_lightHandler->getEnvPrefilteredMap());
    _imageHandler->releaseRenderResources(_lightHandler->getEnvIrradianceMap());

    _lightHandler->setEnvRadianceMap(envRadianceMap);
    _lightHandler->setEnvIrradianceMap(envIrradianceMap);
    _lightHandler->setEnvPrefilteredMap(nullptr);

    if (!_splitDirectLight)
    {
        _lightRigFilename = _envRadianceFilename;
        _lightRigFilename.removeExtension();
        _lightRigFilename.addExtension(mx::MTLX_EXTENSION);
        _lightRigFilename = _searchPath.find(_lightRigFilename);
        if (_lightRigFilename.exists())
        {
            _lightRigDoc = mx::createDocument();
            mx::readFromXmlFile(_lightRigDoc, _lightRigFilename, _searchPath);
        }
        else
        {
            _lightRigDoc = nullptr;
        }
    }

    _envMaterial = nullptr;
}

void Viewer::applyDirectLights(mx::DocumentPtr doc)
{
    if (_lightRigDoc)
    {
        doc->importLibrary(_lightRigDoc);
        _xincludeFiles.insert(_lightRigFilename);
    }

    try
    {
        std::vector<mx::NodePtr> lights;
        _lightHandler->findLights(doc, lights);
        _lightHandler->registerLights(doc, lights, _genContext);
        _lightHandler->setLightSources(lights);
    }
    catch (std::exception& e)
    {
        std::cerr << "Failed to set up lighting: " << e.what() << std::endl;
    }
}

void Viewer::assignMaterial(mx::MeshPartitionPtr geometry, mx::MaterialPtr material)
{
    if (!geometry || _geometryHandler->getMeshes().empty())
    {
        return;
    }

    if (geometry == getSelectedGeometry())
    {
        setSelectedMaterial(material);
        if (material)
        {
            updateDisplayedProperties();
        }
    }

    if (material)
    {
        _materialAssignments[geometry] = material;
        material->unbindGeometry();
    }
    else
    {
        _materialAssignments.erase(geometry);
    }
}

mx::FilePath Viewer::getBaseOutputPath()
{
    mx::FilePath baseFilename = _searchPath.find(_materialFilename);
    baseFilename.removeExtension();
    mx::FilePath outputPath = mx::getEnviron("MATERIALX_VIEW_OUTPUT_PATH");
    if (!outputPath.isEmpty())
    {
        baseFilename = outputPath / baseFilename.getBaseName();
    }
    return baseFilename;
}

mx::ElementPredicate Viewer::getElementPredicate()
{
    return [this](mx::ConstElementPtr elem)
    {
        if (elem->hasSourceUri())
        {
            return (_xincludeFiles.count(elem->getSourceUri()) == 0);
        }
        return true;
    };
}

void Viewer::loadMesh(const mx::FilePath& filename)
{
    _geometryHandler->clearGeometry();
    if (_geometryHandler->loadGeometry(filename))
    {
        _meshFilename = filename;
        initCamera();
    }
}

void Viewer::loadDocument(const mx::FilePath& filename, mx::DocumentPtr libraries)
{
    mx::DocumentPtr doc = mx::createDocument();
    try
    {
        mx::readFromXmlFile(doc, filename, _searchPath);
        doc->importLibrary(libraries);
        applyModifiers(doc, _modifiers);
        applyDirectLights(doc);

        std::vector<mx::MaterialPtr> newMaterials;
        std::vector<mx::NodePtr> materialNodes = doc->getMaterialNodes();
        for (auto materialNode : materialNodes)
        {
            mx::MaterialPtr material = _renderPipeline->createMaterial();
            material->setDocument(doc);
            material->setElement(materialNode);
            material->setMaterialNode(materialNode);
            newMaterials.push_back(material);
        }

        if (newMaterials.empty())
        {
            std::cerr << "No materials found in document" << std::endl;
            return;
        }

        _materials = newMaterials;
        _selectedMaterial = 0;

        updateMaterialSelections();
        reloadShaders();
    }
    catch (std::exception& e)
    {
        std::cerr << "Failed to load document: " << e.what() << std::endl;
    }
}

void Viewer::reloadShaders()
{
    std::cout << "[MaterialX Viewer LOG] Compiling shaders for " << _materials.size() << " materials..." << std::endl;
    for (size_t i = 0; i < _materials.size(); i++)
    {
        auto material = _materials[i];
        try
        {
            std::cout << "[MaterialX Viewer LOG] Generating MSL shader for material index " << i 
                      << " (node name: " << (material->getMaterialNode() ? material->getMaterialNode()->getName() : "unknown") << ")..." << std::endl;
            material->generateShader(_genContext);
            
            auto mslMaterial = std::static_pointer_cast<mx::MslMaterial>(material);
            if (mslMaterial && mslMaterial->getProgram())
            {
                std::cout << "[MaterialX Viewer LOG] Successfully generated MSL program for material index " << i << std::endl;
            }
            else
            {
                std::cerr << "[MaterialX Viewer ERROR] MSL program generated as nullptr for material index " << i << std::endl;
            }
        }
        catch (std::exception& e)
        {
            std::cerr << "[MaterialX Viewer ERROR] Failed to generate shader for material index " << i << ": " << e.what() << std::endl;
        }
    }
}

void Viewer::loadStandardLibraries()
{
    try
    {
        _stdLib = mx::createDocument();
        _xincludeFiles = mx::loadLibraries(_libraryFolders, _searchPath, _stdLib);
        if (_xincludeFiles.empty())
        {
            std::cerr << "Could not find standard data libraries on the given search path: " << _searchPath.asString() << std::endl;
        }
    }
    catch (std::exception& e)
    {
        std::cerr << "Failed to load standard data libraries: " << e.what() << std::endl;
        return;
    }

    mx::UnitTypeDefPtr distanceTypeDef = _stdLib->getUnitTypeDef("distance");
    _distanceUnitConverter = mx::LinearUnitConverter::create(distanceTypeDef);
    _unitRegistry->addUnitConverter(distanceTypeDef, _distanceUnitConverter);
    mx::UnitTypeDefPtr angleTypeDef = _stdLib->getUnitTypeDef("angle");
    mx::LinearUnitConverterPtr angleConverter = mx::LinearUnitConverter::create(angleTypeDef);
    _unitRegistry->addUnitConverter(angleTypeDef, angleConverter);

    initContext(_genContext);
}

void Viewer::initContext(mx::GenContext& context)
{
    context.registerSourceCodeSearchPath(_searchPath);
    mx::ColorManagementSystemPtr cms = mx::DefaultColorManagementSystem::create(context.getShaderGenerator().getTarget());
    cms->loadLibrary(_stdLib);
    context.getShaderGenerator().setColorManagementSystem(cms);

    mx::UnitSystemPtr unitSystem = mx::UnitSystem::create(context.getShaderGenerator().getTarget());
    unitSystem->loadLibrary(_stdLib);
    unitSystem->setUnitConverterRegistry(_unitRegistry);
    context.getShaderGenerator().setUnitSystem(unitSystem);
    context.getOptions().targetDistanceUnit = "meter";
}

void Viewer::saveShaderSource(mx::GenContext& context) {}
void Viewer::loadShaderSource() {}
void Viewer::saveDotFiles() {}

mx::UnsignedIntPair Viewer::computeBakingResolution(mx::ConstDocumentPtr doc)
{
    return mx::UnsignedIntPair(512, 512);
}

mx::DocumentPtr Viewer::translateMaterial()
{
    return nullptr;
}

void Viewer::updateGeometrySelections()
{
    _geometryList.clear();
    for (auto mesh : _geometryHandler->getMeshes())
    {
        for (size_t i = 0; i < mesh->getPartitionCount(); i++)
        {
            _geometryList.push_back(mesh->getPartition(i));
        }
    }
    _selectedGeom = 0;
}

void Viewer::updateMaterialSelections()
{
    _materialAssignments.clear();
    for (auto geom : _geometryList)
    {
        assignMaterial(geom, _materials[_selectedMaterial]);
    }
}

void Viewer::updateMaterialSelectionUI() {}
void Viewer::updateDisplayedProperties() {}

void Viewer::draw_contents()
{
    updateCameras();

    constexpr auto FRAME_MAX_VALUE = std::numeric_limits<decltype(_renderPipeline->_frame)>::max();
    _renderPipeline->_frame = (_renderPipeline->_frame + 1) % FRAME_MAX_VALUE;
    try
    {
        _renderPipeline->renderFrame(_colorTexture,
                                     SHADOW_MAP_SIZE,
                                     DIR_LIGHT_NODE_CATEGORY.c_str());
    }
    catch (std::exception& e)
    {
        std::cerr << "Failed to render frame: " << e.what() << std::endl;
    }
}

void Viewer::initCamera()
{
    _viewCamera->setViewportSize(mx::Vector2(static_cast<float>(m_size[0]), static_cast<float>(m_size[1])));

    _userCameraEnabled = _cameraTarget == mx::Vector3(0.0) &&
                         _meshScale == 1.0f;

    if (!_userCameraEnabled || _geometryHandler->getMeshes().empty())
    {
        return;
    }

    const mx::Vector3& boxMax = _geometryHandler->getMaximumBounds();
    const mx::Vector3& boxMin = _geometryHandler->getMinimumBounds();
    mx::Vector3 sphereCenter = (boxMax + boxMin) * 0.5;

    float turntableRotation = fmod((360.0f / _turntableSteps) * _turntableStep, 360.0f);
    float yRotation = _meshRotation[1] + (_turntableEnabled ? turntableRotation : 0.0f);
    mx::Matrix44 meshRotation = mx::Matrix44::createRotationZ(_meshRotation[2] / 180.0f * PI) *
                                mx::Matrix44::createRotationY(yRotation / 180.0f * PI) *
                                mx::Matrix44::createRotationX(_meshRotation[0] / 180.0f * PI);
    _meshTranslation = -meshRotation.transformPoint(sphereCenter);
    _meshScale = IDEAL_MESH_SPHERE_RADIUS / (sphereCenter - boxMin).getMagnitude();
}

void Viewer::updateCameras()
{
    auto& createPerspectiveMatrix = mx::Camera::createPerspectiveMatrixZP;
    auto& createOrthographicMatrix = mx::Camera::createOrthographicMatrixZP;

    mx::Matrix44 viewMatrix, projectionMatrix;
    float aspectRatio = (float) m_size[0] / (float) m_size[1];
    if (_cameraViewAngle != 0.0f)
    {
        viewMatrix = mx::Camera::createViewMatrix(_cameraPosition, _cameraTarget, _cameraUp);
        float fH = std::tan(_cameraViewAngle / 360.0f * PI) * _cameraNearDist;
        float fW = fH * aspectRatio;
        projectionMatrix = createPerspectiveMatrix(-fW, fW, -fH, fH, _cameraNearDist, _cameraFarDist);
    }
    else
    {
        viewMatrix = mx::Matrix44::createTranslation(mx::Vector3(0.0f, 0.0f, -ORTHO_VIEW_DISTANCE));
        float fH = ORTHO_PROJECTION_HEIGHT;
        float fW = fH * aspectRatio;
        projectionMatrix = createOrthographicMatrix(-fW, fW, -fH, fH, 0.0f, ORTHO_VIEW_DISTANCE + _cameraFarDist);
    }

    projectionMatrix[1][1] = -projectionMatrix[1][1];

    float turntableRotation = fmod((360.0f / _turntableSteps) * _turntableStep, 360.0f);
    float yRotation = _meshRotation[1] + (_turntableEnabled ? turntableRotation : 0.0f);
    mx::Matrix44 meshRotation = mx::Matrix44::createRotationZ(_meshRotation[2] / 180.0f * PI) *
                                mx::Matrix44::createRotationY(yRotation / 180.0f * PI) *
                                mx::Matrix44::createRotationX(_meshRotation[0] / 180.0f * PI);

    mx::Matrix44 arcball = mx::Matrix44::IDENTITY;
    if (_userCameraEnabled)
    {
        arcball = _viewCamera->arcballMatrix();
    }

    _viewCamera->setWorldMatrix(meshRotation *
                                mx::Matrix44::createTranslation(_meshTranslation + _userTranslation) *
                                mx::Matrix44::createScale(mx::Vector3(_meshScale * _cameraZoom)));
    _viewCamera->setViewMatrix(arcball * viewMatrix);
    _viewCamera->setProjectionMatrix(projectionMatrix);

    _envCamera->setWorldMatrix(mx::Matrix44::createScale(mx::Vector3(300.0f)));
    _envCamera->setViewMatrix(_viewCamera->getViewMatrix());
    _envCamera->setProjectionMatrix(_viewCamera->getProjectionMatrix());

    mx::NodePtr dirLight = !_materialAssignments.empty() ? _lightHandler->getFirstLightOfCategory(DIR_LIGHT_NODE_CATEGORY) : nullptr;
    if (dirLight)
    {
        mx::Vector3 sphereCenter = (_geometryHandler->getMaximumBounds() + _geometryHandler->getMinimumBounds()) * 0.5;
        float r = (sphereCenter - _geometryHandler->getMinimumBounds()).getMagnitude();
        _shadowCamera->setWorldMatrix(meshRotation * mx::Matrix44::createTranslation(-sphereCenter));
        _shadowCamera->setProjectionMatrix(mx::Camera::createOrthographicMatrixZP(-r, r, -r, r, 0.0f, r * 2.0f));
        mx::ValuePtr value = dirLight->getInputValue("direction");
        if (value->isA<mx::Vector3>())
        {
            mx::Vector3 dir = mx::Matrix44::createRotationY(_lightRotation / 180.0f * PI).transformVector(value->asA<mx::Vector3>());
            _shadowCamera->setViewMatrix(mx::Camera::createViewMatrix(dir * -r, mx::Vector3(0.0f), _cameraUp));
        }
    }
}

mx::ImagePtr Viewer::getAmbientOcclusionImage(mx::MaterialPtr material)
{
    const mx::string AO_FILENAME_SUFFIX = "_ao";
    const mx::string AO_FILENAME_EXTENSION = "png";

    if (!material || !_genContext.getOptions().hwAmbientOcclusion)
    {
        return nullptr;
    }

    std::string aoSuffix = material->getUdim().empty() ? AO_FILENAME_SUFFIX : AO_FILENAME_SUFFIX + "_" + material->getUdim();
    mx::FilePath aoFilename = _meshFilename;
    aoFilename.removeExtension();
    aoFilename = aoFilename.asString() + aoSuffix;
    aoFilename.addExtension(AO_FILENAME_EXTENSION);
    return _imageHandler->acquireImage(aoFilename);
}

void Viewer::splitDirectLight(mx::ImagePtr envRadianceMap, mx::ImagePtr& indirectMap, mx::DocumentPtr& dirLightDoc)
{
    mx::Vector3 lightDir;
    mx::Color3 lightColor;
    mx::ImagePair imagePair = envRadianceMap->splitByLuminance(ENV_MAP_SPLIT_RADIANCE);

    mx::computeDominantLight(imagePair.second, lightDir, lightColor);
    float lightIntensity = std::max(std::max(lightColor[0], lightColor[1]), lightColor[2]);
    if (lightIntensity)
    {
        lightColor /= lightIntensity;
    }

    dirLightDoc = mx::createDocument();
    mx::NodePtr dirLightNode = dirLightDoc->addNode(DIR_LIGHT_NODE_CATEGORY, "dir_light", mx::LIGHT_SHADER_TYPE_STRING);
    dirLightNode->setInputValue("direction", lightDir);
    dirLightNode->setInputValue("color", lightColor);
    dirLightNode->setInputValue("intensity", lightIntensity);
    indirectMap = imagePair.first;
}

mx::MaterialPtr Viewer::getEnvironmentMaterial()
{
    if (!_envMaterial)
    {
        mx::FilePath envFilename = _searchPath.find(mx::FilePath("resources/Lights/environment_map.mtlx"));
        try
        {
            _envMaterial = _renderPipeline->createMaterial();
            _envMaterial->generateEnvironmentShader(_genContext, envFilename, _stdLib, _envRadianceFilename);
        }
        catch (std::exception& e)
        {
            std::cerr << "Failed to generate environment shader: " << e.what() << std::endl;
            _envMaterial = nullptr;
        }
    }

    return _envMaterial;
}

mx::MaterialPtr Viewer::getWireframeMaterial()
{
    if (!_wireMaterial)
    {
        try
        {
            mx::ShaderPtr hwShader = mx::createConstantShader(_genContext, _stdLib, "__WIRE_SHADER__", mx::Color3(1.0f));
            _wireMaterial = _renderPipeline->createMaterial();
            _wireMaterial->generateShader(hwShader);
        }
        catch (std::exception& e)
        {
            std::cerr << "Failed to generate wireframe shader: " << e.what() << std::endl;
            _wireMaterial = nullptr;
        }
    }

    return _wireMaterial;
}

mx::ImagePtr Viewer::getShadowMap() { return nullptr; }

void Viewer::invalidateShadowMap()
{
    if (_shadowMap)
    {
        _imageHandler->releaseRenderResources(_shadowMap);
        _shadowMap = nullptr;
    }
}

void Viewer::toggleTurntable(bool enable)
{
    _turntableEnabled = enable;
    if (enable)
    {
        _turntableTimer.startTimer();
    }
    else
    {
        float turntableRotation = fmod((360.0f / _turntableSteps) * _turntableStep, 360.0f);
        _meshRotation[1] = fmod(_meshRotation[1] + turntableRotation, 360.0f);
        _turntableTimer.endTimer();
    }
    invalidateShadowMap();
    _turntableStep = 0;
}

void Viewer::setShaderInterfaceType(mx::ShaderInterfaceType interfaceType)
{
    _genContext.getOptions().shaderInterfaceType = interfaceType;
    reloadShaders();
}

void Viewer::renderTurnable() {}
void Viewer::renderScreenSpaceQuad(mx::MaterialPtr material) {}
void Viewer::updateAlbedoTable() {}
mx::ImagePtr Viewer::renderWedge() { return nullptr; }
